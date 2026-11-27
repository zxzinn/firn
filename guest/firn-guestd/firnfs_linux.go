//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

type firnSyntheticKind uint8

const (
	syntheticModify firnSyntheticKind = 1 + iota
	syntheticCreate
	syntheticMkdir
	syntheticDelete
	syntheticRmdir
)

type firnSyntheticEvent struct {
	rel string
}

type firnFSMount struct {
	server      *fuse.Server
	client      *firnFSClient
	root        *firnFSNode
	cache       *firnFSCache
	backingDir  string
	mountPoint  string
	synthTID    atomic.Uint32
	renameEpoch atomic.Uint64

	synthMu         sync.RWMutex
	syntheticNotify map[string]firnSyntheticKind
	knownDirs       map[string]struct{}
	recentDel       map[string]time.Time
	notifyCh        chan firnSyntheticEvent
	stopCh          chan struct{}
	stopOnce        sync.Once
}

func detectVirtioFSBacking() string {
	const candidate = "/mnt/virtiofs-home"
	raw, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[1] == candidate && fields[2] == "virtiofs" {
			if st, serr := os.Stat(candidate); serr == nil && st.IsDir() {
				return candidate
			}
		}
	}
	return ""
}

func (m *firnFSMount) backingPath(rel string) string {
	if m.backingDir == "" {
		return ""
	}
	if rel == "" {
		return m.backingDir
	}
	return filepath.Join(m.backingDir, filepath.FromSlash(rel))
}

func (m *firnFSMount) mountFilePath(rel string) string {
	if rel == "" {
		return m.mountPoint
	}
	return filepath.Join(m.mountPoint, filepath.FromSlash(rel))
}

func (m *firnFSMount) setSynthetic(rel string, kind firnSyntheticKind) {
	m.synthMu.Lock()
	m.syntheticNotify[rel] = kind
	m.synthMu.Unlock()
}

func (m *firnFSMount) clearSynthetic(rel string, kind firnSyntheticKind) {
	m.synthMu.Lock()
	if cur, ok := m.syntheticNotify[rel]; ok && cur == kind {
		delete(m.syntheticNotify, rel)
	}
	m.synthMu.Unlock()
}

func (m *firnFSMount) syntheticKindFor(ctx context.Context, rel string) (firnSyntheticKind, bool) {
	caller, ok := fuse.FromContext(ctx)
	tid := m.synthTID.Load()
	if !ok || tid == 0 || caller.Pid != tid {
		return 0, false
	}
	m.synthMu.RLock()
	kind, exists := m.syntheticNotify[rel]
	m.synthMu.RUnlock()
	return kind, exists
}

func (m *firnFSMount) isSyntheticCallerKind(ctx context.Context, rel string, want firnSyntheticKind) bool {
	kind, ok := m.syntheticKindFor(ctx, rel)
	return ok && kind == want
}

func (m *firnFSMount) markDir(rel string) {
	if rel == "" {
		return
	}
	m.synthMu.Lock()
	if m.knownDirs != nil {
		m.knownDirs[rel] = struct{}{}
	}
	if m.recentDel != nil {
		delete(m.recentDel, rel)
	}
	m.synthMu.Unlock()
}

func (m *firnFSMount) clearRecentDel(rel string) {
	if rel == "" {
		return
	}
	m.synthMu.Lock()
	if m.recentDel != nil {
		delete(m.recentDel, rel)
	}
	m.synthMu.Unlock()
}

func (m *firnFSMount) isKnownDir(rel string) bool {
	m.synthMu.RLock()
	_, ok := m.knownDirs[rel]
	m.synthMu.RUnlock()
	return ok
}

func (m *firnFSMount) markDeletedRecently(rel string) bool {
	now := time.Now()
	m.synthMu.Lock()
	defer m.synthMu.Unlock()
	if m.recentDel == nil {
		m.recentDel = make(map[string]time.Time)
	}
	if prev, ok := m.recentDel[rel]; ok && now.Sub(prev) < 400*time.Millisecond {
		return false
	}
	if len(m.recentDel) > 512 {
		for k, t := range m.recentDel {
			if now.Sub(t) >= time.Second {
				delete(m.recentDel, k)
			}
		}
	}
	m.recentDel[rel] = now
	if m.knownDirs != nil {
		delete(m.knownDirs, rel)
	}
	return true
}

func syntheticStubIno(rel string) uint64 {
	var h uint64 = 14695981039346656037
	for i := 0; i < len(rel); i++ {
		h ^= uint64(rel[i])
		h *= 1099511628211
	}
	return (h & 0x7fffffffffffffff) | (1 << 62)
}

func startFirnFS(mountPoint, hostAddr string) (*firnFSMount, error) {
	_ = syscall.Unmount(mountPoint, syscall.MNT_DETACH)
	if err := os.MkdirAll(mountPoint, 0o755); err != nil {
		return nil, err
	}
	cache := newFirnFSCache(firnFSCacheMaxBytes, firnFSCacheMaxEntries)
	backing := detectVirtioFSBacking()
	mountObj := &firnFSMount{
		cache:           cache,
		backingDir:      backing,
		mountPoint:      mountPoint,
		syntheticNotify: make(map[string]firnSyntheticKind),
		knownDirs:       make(map[string]struct{}),
		recentDel:       make(map[string]time.Time),
		notifyCh:        make(chan firnSyntheticEvent, 4096),
		stopCh:          make(chan struct{}),
	}

	var rootNode *firnFSNode
	client := newFirnFSClientWithDialer(hostAddr, func() (net.Conn, error) {
		if vc, err := DialVsockHost(2385); err == nil {
			return vc, nil
		}
		c, err := net.DialTimeout("tcp", hostAddr, 2*time.Second)
		if err != nil {
			return nil, err
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
			_ = tc.SetReadBuffer(4 << 20)
			_ = tc.SetWriteBuffer(4 << 20)
		}
		return c, nil
	}, func(paths []string) {
		nowNs := time.Now().UnixNano()
		nonEcho := make([]string, 0, len(paths))
		for _, raw := range paths {
			rel := cleanFirnFSRelPath(raw)
			if cache.IsRecentLocalEcho(rel, nowNs) {
				continue
			}
			cache.InvalidatePath(rel)
			nonEcho = append(nonEcho, rel)
		}
		if rootNode != nil && len(nonEcho) > 0 {
			mountObj.notifyKernelInvalidateBatch(nonEcho)
		}
	})
	client.SetOnPrefetch(cache.PutDirPrefetch)
	if _, err := client.ensureConn(); err != nil {
		client.Close()
		return nil, err
	}
	mountObj.client = client

	rootNode = &firnFSNode{fsys: mountObj, pathValid: true}
	mountObj.root = rootNode

	ttl := 60 * time.Second
	negTTL := 2 * time.Second
	opts := &fs.Options{
		MountOptions: fuse.MountOptions{
			AllowOther:               true,
			DirectMount:              true,
			MaxWrite:                 1 << 20,
			MaxBackground:            64,
			ExplicitDataCacheControl: true,
			EnableSymlinkCaching:     true,
			ExtraCapabilities:        fuse.CAP_WRITEBACK_CACHE,
			FsName:                   "firnfs",
			Name:                     "firnfs",
		},
		EntryTimeout:    &ttl,
		AttrTimeout:     &ttl,
		NegativeTimeout: &negTTL,
		NullPermissions: true,
	}

	srv, err := fs.Mount(mountPoint, rootNode, opts)
	if err != nil {
		client.Close()
		return nil, err
	}
	mountObj.server = srv
	go mountObj.runSyntheticWorker()
	log.Printf("[firn-guestd] firnfs mounted at %s -> vsock:2385/%s (backing=%q, cache 64MiB + FSEvents + inotify v3)", mountPoint, hostAddr, backing)
	return mountObj, nil
}

func (m *firnFSMount) Unmount() {
	m.stopOnce.Do(func() {
		if m.stopCh != nil {
			close(m.stopCh)
		}
	})
	if m.server != nil {
		_ = m.server.Unmount()
	}
	if m.client != nil {
		m.client.Close()
	}
}

func (m *firnFSMount) notifyKernelInvalidateBatch(rawPaths []string) {
	for _, raw := range rawPaths {
		rel := cleanFirnFSRelPath(raw)
		if m.notifyCh == nil {
			m.notifyKernelInvalidate(rel)
			continue
		}
		select {
		case m.notifyCh <- firnSyntheticEvent{rel: rel}:
		default:
			m.notifyKernelInvalidate(rel)
		}
	}
}

func (m *firnFSMount) runSyntheticWorker() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	m.synthTID.Store(uint32(syscall.Gettid()))
	for {
		select {
		case <-m.stopCh:
			return
		case first := <-m.notifyCh:
			batch := []string{first.rel}
			seen := map[string]struct{}{first.rel: {}}
		drainLoop:
			for len(batch) < 512 {
				select {
				case ev := <-m.notifyCh:
					if _, ok := seen[ev.rel]; !ok {
						seen[ev.rel] = struct{}{}
						batch = append(batch, ev.rel)
					}
				default:
					break drainLoop
				}
			}
			m.applySyntheticBatch(batch)
		}
	}
}

func (m *firnFSMount) hostLookup(rel string) (fsAttrWire, bool) {
	if m.client != nil {
		var req bytes.Buffer
		writeShortStr(&req, rel)
		if resp, err := m.client.call(fsOpLookup, req.Bytes()); err == nil {
			ec, attr := decodeErrnoAndAttr(resp)
			return attr, ec == 0
		}
	}
	if full := m.backingPath(rel); full != "" {
		if attr, ec := lstatLinuxAttr(full); ec == 0 {
			return attr, true
		}
	}
	return fsAttrWire{}, false
}

func (m *firnFSMount) applySyntheticBatch(batch []string) {
	if m.root == nil {
		return
	}
	type pathState struct {
		rel    string
		depth  int
		exists bool
		attr   fsAttrWire
	}
	var deletes, upserts []pathState
	seenParents := make(map[*fs.Inode]struct{})
	for _, rel := range batch {
		if rel == "" {
			m.notifyKernelInvalidateWithSeen("", seenParents)
			continue
		}
		attr, exists := m.hostLookup(rel)
		if exists && m.cache != nil {
			m.cache.PutEntry(rel, attr, nil, false)
		}
		ps := pathState{
			rel:    rel,
			depth:  strings.Count(rel, "/"),
			exists: exists,
			attr:   attr,
		}
		if exists {
			upserts = append(upserts, ps)
		} else {
			deletes = append(deletes, ps)
		}
	}
	sort.Slice(deletes, func(i, j int) bool {
		if deletes[i].depth != deletes[j].depth {
			return deletes[i].depth > deletes[j].depth
		}
		return deletes[i].rel < deletes[j].rel
	})
	sort.Slice(upserts, func(i, j int) bool {
		if upserts[i].depth != upserts[j].depth {
			return upserts[i].depth < upserts[j].depth
		}
		return upserts[i].rel < upserts[j].rel
	})
	for _, item := range deletes {
		m.applySyntheticOne(item.rel, false, fsAttrWire{}, seenParents)
	}
	for _, item := range upserts {
		m.applySyntheticOne(item.rel, true, item.attr, seenParents)
	}
}

func (m *firnFSMount) walkParentInode(rel string) (*fs.Inode, string) {
	if m.root == nil || rel == "" {
		return nil, ""
	}
	parts := strings.Split(rel, "/")
	parent := &m.root.Inode
	for i := 0; i < len(parts)-1 && parent != nil; i++ {
		if parts[i] == "" {
			continue
		}
		parent = parent.GetChild(parts[i])
	}
	if parent == nil {
		return nil, ""
	}
	return parent, parts[len(parts)-1]
}

func (m *firnFSMount) applySyntheticOne(rel string, hostExists bool, attr fsAttrWire, seenParents map[*fs.Inode]struct{}) {
	select {
	case <-m.stopCh:
		return
	default:
	}
	parent, name := m.walkParentInode(rel)
	if parent == nil || name == "" {
		return
	}
	child := parent.GetChild(name)
	mountTarget := m.mountFilePath(rel)

	switch {
	case hostExists && child == nil:
		m.clearRecentDel(rel)
		mode := attr.Mode & syscall.S_IFMT
		if mode == syscall.S_IFDIR {
			m.markDir(rel)
			m.setSynthetic(rel, syntheticMkdir)
			err := os.Mkdir(mountTarget, 0o755)
			m.clearSynthetic(rel, syntheticMkdir)
			if err == nil {
				_ = parent.NotifyContent(0, 0)
				return
			}
		} else if mode == syscall.S_IFREG {
			m.setSynthetic(rel, syntheticCreate)
			f, err := os.OpenFile(mountTarget, os.O_CREATE|os.O_WRONLY, 0o644)
			if err == nil {
				if attr.Size > 0 {
					_, _ = f.Write([]byte{0})
				}
				_ = f.Close()
			}
			m.clearSynthetic(rel, syntheticCreate)
			if err == nil {
				_ = parent.NotifyContent(0, 0)
				return
			}
		}
		m.notifyKernelInvalidateWithSeen(rel, seenParents)

	case hostExists && child != nil:
		m.clearRecentDel(rel)
		mode := attr.Mode & syscall.S_IFMT
		if mode == syscall.S_IFDIR {
			m.markDir(rel)
		}
		if mode == syscall.S_IFREG && !child.IsDir() {
			m.setSynthetic(rel, syntheticModify)
			f, err := os.OpenFile(mountTarget, os.O_WRONLY, 0)
			if err == nil {
				_, _ = f.Write([]byte{0})
				_ = f.Close()
			}
			m.clearSynthetic(rel, syntheticModify)
		}
		m.notifyKernelInvalidateWithSeen(rel, seenParents)

	default:
		if !m.markDeletedRecently(rel) {
			return
		}
		wasDir := (child != nil && child.IsDir()) || m.isKnownDir(rel)
		kind := syntheticDelete
		if wasDir {
			kind = syntheticRmdir
		}
		m.setSynthetic(rel, kind)
		var delErr error
		if wasDir {
			delErr = syscall.Rmdir(mountTarget)
		} else {
			delErr = syscall.Unlink(mountTarget)
		}
		m.clearSynthetic(rel, kind)
		if delErr == nil {
			_ = parent.NotifyContent(0, 0)
			return
		}
		m.notifyKernelInvalidateWithSeen(rel, seenParents)
	}
}

func (m *firnFSMount) notifyKernelInvalidate(rel string) {
	m.notifyKernelInvalidateWithSeen(rel, nil)
}

func (m *firnFSMount) notifyKernelInvalidateWithSeen(rel string, seenParents map[*fs.Inode]struct{}) {
	rootInode := &m.root.Inode
	if rel == "" {
		_ = rootInode.NotifyContent(0, 0)
		return
	}
	parts := strings.Split(rel, "/")
	parent := rootInode
	for i := 0; i < len(parts)-1 && parent != nil; i++ {
		if parts[i] == "" {
			continue
		}
		parent = parent.GetChild(parts[i])
	}
	if parent == nil {
		return
	}
	name := parts[len(parts)-1]
	if child := parent.GetChild(name); child != nil {
		_ = child.NotifyContent(0, 0)
	}
	_ = parent.NotifyEntry(name)
	if seenParents == nil {
		_ = parent.NotifyContent(0, 0)
	} else if _, done := seenParents[parent]; !done {
		seenParents[parent] = struct{}{}
		_ = parent.NotifyContent(0, 0)
	}
}

func errToErrno(err error) syscall.Errno {
	if err == nil {
		return 0
	}
	var se syscall.Errno
	if errors.As(err, &se) {
		return se
	}
	return syscall.EIO
}

func statTToWire(st *syscall.Stat_t) fsAttrWire {
	return fsAttrWire{
		Ino:     st.Ino,
		Size:    uint64(st.Size),
		Blocks:  uint64(st.Blocks),
		AtimeNs: st.Atim.Nano(),
		MtimeNs: st.Mtim.Nano(),
		CtimeNs: st.Ctim.Nano(),
		Mode:    st.Mode,
		Nlink:   uint32(st.Nlink),
		UID:     st.Uid,
		GID:     st.Gid,
	}
}

func lstatLinuxAttr(fullPath string) (fsAttrWire, syscall.Errno) {
	var st syscall.Stat_t
	if err := syscall.Lstat(fullPath, &st); err != nil {
		return fsAttrWire{}, errToErrno(err)
	}
	return statTToWire(&st), 0
}

func fstatLinuxAttr(fd int) (fsAttrWire, syscall.Errno) {
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return fsAttrWire{}, errToErrno(err)
	}
	return statTToWire(&st), 0
}

type firnFSFileHandle struct {
	mu        sync.Mutex
	file      *os.File
	rel       string
	fsys      *firnFSMount
	synthetic bool
}

var (
	_ = (fs.FileReader)((*firnFSFileHandle)(nil))
	_ = (fs.FileWriter)((*firnFSFileHandle)(nil))
	_ = (fs.FileFsyncer)((*firnFSFileHandle)(nil))
	_ = (fs.FileReleaser)((*firnFSFileHandle)(nil))
)

func (h *firnFSFileHandle) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if h.synthetic {
		return fuse.ReadResultData(nil), 0
	}
	h.mu.Lock()
	f := h.file
	h.mu.Unlock()
	if f == nil {
		return nil, syscall.EBADF
	}
	n, err := f.ReadAt(dest, off)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, errToErrno(err)
	}
	return fuse.ReadResultData(dest[:n]), 0
}

func (h *firnFSFileHandle) Write(ctx context.Context, data []byte, off int64) (uint32, syscall.Errno) {
	if h.synthetic {
		return uint32(len(data)), 0
	}
	h.mu.Lock()
	f := h.file
	h.mu.Unlock()
	if f == nil {
		return 0, syscall.EBADF
	}
	n, err := f.WriteAt(data, off)
	var minSize uint64
	if off >= 0 && n >= 0 {
		minSize = uint64(off) + uint64(n)
	}
	h.fsys.cache.UpdateWriteAttr(h.rel, minSize, time.Now().UnixNano())
	if err != nil {
		return uint32(n), errToErrno(err)
	}
	return uint32(n), 0
}

func (h *firnFSFileHandle) Fsync(ctx context.Context, flags uint32) syscall.Errno {
	if h.synthetic {
		return 0
	}
	h.mu.Lock()
	f := h.file
	h.mu.Unlock()
	if f == nil {
		return syscall.EBADF
	}
	return errToErrno(f.Sync())
}

func (h *firnFSFileHandle) Release(ctx context.Context) syscall.Errno {
	h.mu.Lock()
	f := h.file
	h.file = nil
	h.mu.Unlock()
	if f == nil {
		return 0
	}
	return errToErrno(f.Close())
}

type firnFSDirHandle struct {
	mu      sync.Mutex
	idx     int
	entries []fuse.DirEntry
}

var (
	_ = (fs.FileReaddirenter)((*firnFSDirHandle)(nil))
	_ = (fs.FileSeekdirer)((*firnFSDirHandle)(nil))
	_ = (fs.FileReleasedirer)((*firnFSDirHandle)(nil))
)

func (d *firnFSDirHandle) Readdirent(ctx context.Context) (*fuse.DirEntry, syscall.Errno) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.idx >= len(d.entries) {
		return nil, 0
	}
	e := d.entries[d.idx]
	d.idx++
	e.Off = uint64(d.idx)
	return &e, 0
}

func (d *firnFSDirHandle) Seekdir(ctx context.Context, off uint64) syscall.Errno {
	d.mu.Lock()
	defer d.mu.Unlock()
	idx := int(off)
	if idx < 0 || idx > len(d.entries) {
		return syscall.EINVAL
	}
	d.idx = idx
	return 0
}

func (d *firnFSDirHandle) Releasedir(ctx context.Context, releaseFlags uint32) {}

type firnFSNode struct {
	fs.Inode
	fsys        *firnFSMount
	pathMu      sync.RWMutex
	cachedRel   string
	cachedEpoch uint64
	pathValid   bool
}

var (
	_ = (fs.NodeLookuper)((*firnFSNode)(nil))
	_ = (fs.NodeGetattrer)((*firnFSNode)(nil))
	_ = (fs.NodeSetattrer)((*firnFSNode)(nil))
	_ = (fs.NodeOpendirHandler)((*firnFSNode)(nil))
	_ = (fs.NodeReaddirer)((*firnFSNode)(nil))
	_ = (fs.NodeOpener)((*firnFSNode)(nil))
	_ = (fs.NodeReader)((*firnFSNode)(nil))
	_ = (fs.NodeWriter)((*firnFSNode)(nil))
	_ = (fs.NodeCreater)((*firnFSNode)(nil))
	_ = (fs.NodeMkdirer)((*firnFSNode)(nil))
	_ = (fs.NodeUnlinker)((*firnFSNode)(nil))
	_ = (fs.NodeRmdirer)((*firnFSNode)(nil))
	_ = (fs.NodeRenamer)((*firnFSNode)(nil))
	_ = (fs.NodeSymlinker)((*firnFSNode)(nil))
	_ = (fs.NodeReadlinker)((*firnFSNode)(nil))
	_ = (fs.NodeLinker)((*firnFSNode)(nil))
	_ = (fs.NodeFsyncer)((*firnFSNode)(nil))
	_ = (fs.NodeStatfser)((*firnFSNode)(nil))
)

func (n *firnFSNode) newChildNode(childRel string) *firnFSNode {
	return &firnFSNode{
		fsys:        n.fsys,
		cachedRel:   childRel,
		cachedEpoch: n.fsys.renameEpoch.Load(),
		pathValid:   true,
	}
}

func (n *firnFSNode) relPath() string {
	epoch := n.fsys.renameEpoch.Load()
	n.pathMu.RLock()
	if n.pathValid && n.cachedEpoch == epoch {
		rel := n.cachedRel
		n.pathMu.RUnlock()
		return rel
	}
	n.pathMu.RUnlock()

	p := n.Path(n.Root())
	rel := ""
	if p != "" && p != "." {
		rel = strings.TrimPrefix(filepath.ToSlash(p), "/")
	}
	n.pathMu.Lock()
	n.cachedRel = rel
	n.cachedEpoch = epoch
	n.pathValid = true
	n.pathMu.Unlock()
	return rel
}

func fillFuseAttr(src fsAttrWire, dst *fuse.Attr) {
	dst.Ino = src.Ino
	dst.Size = src.Size
	dst.Blocks = src.Blocks
	dst.Atime = uint64(src.AtimeNs / 1e9)
	dst.Atimensec = uint32(src.AtimeNs % 1e9)
	dst.Mtime = uint64(src.MtimeNs / 1e9)
	dst.Mtimensec = uint32(src.MtimeNs % 1e9)
	dst.Ctime = uint64(src.CtimeNs / 1e9)
	dst.Ctimensec = uint32(src.CtimeNs % 1e9)
	dst.Mode = src.Mode
	dst.Nlink = src.Nlink
	dst.Uid = src.UID
	dst.Gid = src.GID
	dst.Blksize = 4096
}

func stableFromWire(a fsAttrWire) fs.StableAttr {
	return fs.StableAttr{
		Mode: a.Mode & syscall.S_IFMT,
		Ino:  a.Ino,
		Gen:  1,
	}
}

func decodeErrnoAndAttr(resp []byte) (syscall.Errno, fsAttrWire) {
	if len(resp) < 4 {
		return syscall.EIO, fsAttrWire{}
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec != 0 {
		return ec, fsAttrWire{}
	}
	off := 4
	attr, ok := decodeFSAttr(resp, &off)
	if !ok {
		return syscall.EIO, fsAttrWire{}
	}
	return 0, attr
}

func (n *firnFSNode) fetchAttr(rel string) (fsAttrWire, syscall.Errno) {
	if attr, _, _, ok := n.fsys.cache.GetEntry(rel); ok {
		return attr, 0
	}
	if full := n.fsys.backingPath(rel); full != "" {
		attr, ec := lstatLinuxAttr(full)
		if ec != 0 {
			return fsAttrWire{}, ec
		}
		n.fsys.cache.PutEntry(rel, attr, nil, false)
		return attr, 0
	}
	var req bytes.Buffer
	writeShortStr(&req, rel)
	resp, err := n.fsys.client.call(fsOpLookup, req.Bytes())
	if err != nil {
		return fsAttrWire{}, syscall.EIO
	}
	ec, attr := decodeErrnoAndAttr(resp)
	if ec != 0 {
		return fsAttrWire{}, ec
	}
	n.fsys.cache.PutEntry(rel, attr, nil, false)
	return attr, 0
}

func (n *firnFSNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	parentRel := n.relPath()
	childRel := joinFirnFSRel(parentRel, name)
	if kind, ok := n.fsys.syntheticKindFor(ctx, childRel); ok {
		switch kind {
		case syntheticCreate, syntheticMkdir:
			return nil, syscall.ENOENT
		case syntheticDelete, syntheticRmdir:
			mode := uint32(syscall.S_IFREG | 0o644)
			if kind == syntheticRmdir {
				mode = uint32(syscall.S_IFDIR | 0o755)
			}
			attr := fsAttrWire{
				Ino:   syntheticStubIno(childRel),
				Mode:  mode,
				Nlink: 1,
			}
			fillFuseAttr(attr, &out.Attr)
			out.SetEntryTimeout(time.Second)
			out.SetAttrTimeout(time.Second)
			child := n.newChildNode(childRel)
			return n.NewInode(ctx, child, stableFromWire(attr)), 0
		}
	}
	if n.fsys.cache.IsKnownAbsent(parentRel, name) {
		return nil, syscall.ENOENT
	}
	attr, ec := n.fetchAttr(childRel)
	if ec != 0 {
		return nil, ec
	}
	if attr.Mode&syscall.S_IFMT == syscall.S_IFDIR {
		n.fsys.markDir(childRel)
	}
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := n.newChildNode(childRel)
	return n.NewInode(ctx, child, stableFromWire(attr)), 0
}

func (n *firnFSNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	rel := n.relPath()
	if fh, ok := f.(*firnFSFileHandle); ok {
		if full := n.fsys.backingPath(fh.rel); full != "" {
			if attr, ec := lstatLinuxAttr(full); ec == 0 {
				fillFuseAttr(attr, &out.Attr)
				out.SetTimeout(60 * time.Second)
				return 0
			}
		}
	}
	attr, ec := n.fetchAttr(rel)
	if ec != 0 {
		return ec
	}
	fillFuseAttr(attr, &out.Attr)
	out.SetTimeout(60 * time.Second)
	return 0
}

func (n *firnFSNode) Setattr(ctx context.Context, f fs.FileHandle, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	rel := n.relPath()
	if n.fsys.isSyntheticCallerKind(ctx, rel, syntheticModify) || n.fsys.isSyntheticCallerKind(ctx, rel, syntheticCreate) {
		if full := n.fsys.backingPath(rel); full != "" {
			if curAttr, ec := lstatLinuxAttr(full); ec == 0 {
				fillFuseAttr(curAttr, &out.Attr)
				out.SetTimeout(time.Second)
				return 0
			}
		}
		return 0
	}
	valid := in.Valid
	atimeNs := int64(in.Atime)*1e9 + int64(in.Atimensec)
	mtimeNs := int64(in.Mtime)*1e9 + int64(in.Mtimensec)
	if (valid & fuse.FATTR_ATIME_NOW) != 0 {
		valid |= fuse.FATTR_ATIME
		atimeNs = time.Now().UnixNano()
	}
	if (valid & fuse.FATTR_MTIME_NOW) != 0 {
		valid |= fuse.FATTR_MTIME
		mtimeNs = time.Now().UnixNano()
	}

	if full := n.fsys.backingPath(rel); full != "" {
		if (valid & fuse.FATTR_SIZE) != 0 {
			if err := os.Truncate(full, int64(in.Size)); err != nil {
				return errToErrno(err)
			}
		}
		if (valid & fuse.FATTR_MODE) != 0 {
			if err := os.Chmod(full, os.FileMode(in.Mode&0o7777)); err != nil {
				return errToErrno(err)
			}
		}
		if (valid & (fuse.FATTR_ATIME | fuse.FATTR_MTIME)) != 0 {
			curAttr, ec := lstatLinuxAttr(full)
			if ec != 0 {
				return ec
			}
			at := time.Unix(0, curAttr.AtimeNs)
			mt := time.Unix(0, curAttr.MtimeNs)
			if (valid & fuse.FATTR_ATIME) != 0 {
				at = time.Unix(0, atimeNs)
			}
			if (valid & fuse.FATTR_MTIME) != 0 {
				mt = time.Unix(0, mtimeNs)
			}
			if err := os.Chtimes(full, at, mt); err != nil {
				return errToErrno(err)
			}
		}
		attr, ec := lstatLinuxAttr(full)
		if ec != 0 {
			return ec
		}
		n.fsys.cache.PutEntry(rel, attr, nil, false)
		fillFuseAttr(attr, &out.Attr)
		out.SetTimeout(60 * time.Second)
		return 0
	}

	var req bytes.Buffer
	writeShortStr(&req, rel)
	var b [40]byte
	binary.BigEndian.PutUint32(b[0:4], valid)
	binary.BigEndian.PutUint32(b[4:8], in.Mode)
	binary.BigEndian.PutUint32(b[8:12], in.Uid)
	binary.BigEndian.PutUint32(b[12:16], in.Gid)
	binary.BigEndian.PutUint64(b[16:24], in.Size)
	binary.BigEndian.PutUint64(b[24:32], uint64(atimeNs))
	binary.BigEndian.PutUint64(b[32:40], uint64(mtimeNs))
	req.Write(b[:])

	resp, err := n.fsys.client.call(fsOpSetattr, req.Bytes())
	if err != nil {
		return syscall.EIO
	}
	ec, attr := decodeErrnoAndAttr(resp)
	if ec != 0 {
		return ec
	}
	n.fsys.cache.PutEntry(rel, attr, nil, false)
	fillFuseAttr(attr, &out.Attr)
	return 0
}

func (n *firnFSNode) loadDirEntries() ([]fuse.DirEntry, syscall.Errno) {
	rel := n.relPath()
	if cached, ok := n.fsys.cache.GetDirPrefetch(rel); ok {
		entries := make([]fuse.DirEntry, 0, len(cached))
		for _, it := range cached {
			entries = append(entries, fuse.DirEntry{
				Mode: it.Attr.Mode & syscall.S_IFMT,
				Name: it.Name,
				Ino:  it.Attr.Ino,
			})
		}
		return entries, 0
	}

	var req bytes.Buffer
	writeShortStr(&req, rel)
	resp, err := n.fsys.client.call(fsOpReaddirPref, req.Bytes())
	if err != nil || len(resp) < 4 {
		return nil, syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec != 0 {
		return nil, ec
	}
	if len(resp) < 8 {
		return nil, syscall.EIO
	}
	cnt := int(binary.BigEndian.Uint32(resp[4:8]))
	off := 8
	items, ok := decodeDirPrefetchItems(resp, &off, cnt, false)
	if !ok {
		return nil, syscall.EIO
	}
	n.fsys.cache.PutDirPrefetch(rel, items)
	entries := make([]fuse.DirEntry, 0, len(items))
	for _, it := range items {
		entries = append(entries, fuse.DirEntry{
			Mode: it.Attr.Mode & syscall.S_IFMT,
			Name: it.Name,
			Ino:  it.Attr.Ino,
		})
	}
	return entries, 0
}

func (n *firnFSNode) OpendirHandle(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	entries, ec := n.loadDirEntries()
	if ec != 0 {
		return nil, 0, ec
	}
	return &firnFSDirHandle{entries: entries}, fuse.FOPEN_CACHE_DIR | fuse.FOPEN_KEEP_CACHE, 0
}

func (n *firnFSNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	entries, ec := n.loadDirEntries()
	if ec != 0 {
		return nil, ec
	}
	return fs.NewListDirStream(entries), 0
}

func (n *firnFSNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	rel := n.relPath()
	if n.fsys.isSyntheticCallerKind(ctx, rel, syntheticModify) {
		return &firnFSFileHandle{rel: rel, fsys: n.fsys, synthetic: true}, fuse.FOPEN_DIRECT_IO, 0
	}
	if (flags & (syscall.O_WRONLY | syscall.O_RDWR | syscall.O_TRUNC | syscall.O_APPEND)) == 0 {
		return nil, fuse.FOPEN_KEEP_CACHE | fuse.FOPEN_NOFLUSH, 0
	}
	if full := n.fsys.backingPath(rel); full != "" {
		oflags := int(flags) &^ (syscall.O_CREAT | syscall.O_EXCL)
		f, err := os.OpenFile(full, oflags, 0)
		if err != nil {
			return nil, 0, errToErrno(err)
		}
		n.fsys.cache.UpdateWriteAttr(rel, 0, time.Now().UnixNano())
		return &firnFSFileHandle{file: f, rel: rel, fsys: n.fsys}, 0, 0
	}
	return nil, 0, 0
}

func (n *firnFSNode) Read(ctx context.Context, f fs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if fh, ok := f.(*firnFSFileHandle); ok {
		return fh.Read(ctx, dest, off)
	}
	rel := n.relPath()
	if _, data, hasData, ok := n.fsys.cache.GetEntry(rel); ok && hasData {
		if off >= int64(len(data)) {
			return fuse.ReadResultData(nil), 0
		}
		end := min(len(data), int(off)+len(dest))
		return fuse.ReadResultData(data[off:end]), 0
	}

	var req bytes.Buffer
	writeShortStr(&req, rel)
	var hdr [12]byte
	binary.BigEndian.PutUint64(hdr[0:8], uint64(off))
	binary.BigEndian.PutUint32(hdr[8:12], uint32(len(dest)))
	req.Write(hdr[:])

	resp, err := n.fsys.client.call(fsOpRead, req.Bytes())
	if err != nil || len(resp) < 4 {
		return nil, syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec != 0 {
		return nil, ec
	}
	if len(resp) < 8 {
		return nil, syscall.EIO
	}
	dlen := int(binary.BigEndian.Uint32(resp[4:8]))
	if 8+dlen > len(resp) {
		return nil, syscall.EIO
	}
	data := resp[8 : 8+dlen]
	if off == 0 && dlen <= 64*1024 && len(data) <= len(dest) {
		if attr, _, _, ok := n.fsys.cache.GetEntry(rel); ok && uint64(dlen) == attr.Size {
			n.fsys.cache.PutEntry(rel, attr, data, true)
		}
	}
	return fuse.ReadResultData(data), 0
}

func (n *firnFSNode) Write(ctx context.Context, f fs.FileHandle, data []byte, off int64) (uint32, syscall.Errno) {
	if fh, ok := f.(*firnFSFileHandle); ok {
		return fh.Write(ctx, data, off)
	}
	rel := n.relPath()
	if full := n.fsys.backingPath(rel); full != "" {
		file, err := os.OpenFile(full, os.O_WRONLY, 0)
		if err != nil {
			return 0, errToErrno(err)
		}
		written, werr := file.WriteAt(data, off)
		_ = file.Close()
		var minSize uint64
		if off >= 0 && written >= 0 {
			minSize = uint64(off) + uint64(written)
		}
		n.fsys.cache.UpdateWriteAttr(rel, minSize, time.Now().UnixNano())
		if werr != nil {
			return uint32(written), errToErrno(werr)
		}
		return uint32(written), 0
	}

	var req bytes.Buffer
	writeShortStr(&req, rel)
	var hdr [16]byte
	binary.BigEndian.PutUint64(hdr[0:8], uint64(off))
	binary.BigEndian.PutUint32(hdr[8:12], 0)
	binary.BigEndian.PutUint32(hdr[12:16], uint32(len(data)))
	req.Write(hdr[:])
	req.Write(data)

	resp, err := n.fsys.client.call(fsOpWrite, req.Bytes())
	if err != nil || len(resp) < 4 {
		return 0, syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec != 0 {
		return 0, ec
	}
	if len(resp) < 8 {
		return 0, syscall.EIO
	}
	written := binary.BigEndian.Uint32(resp[4:8])
	attrOff := 8
	if attr, ok := decodeFSAttr(resp, &attrOff); ok {
		n.fsys.cache.PutEntry(rel, attr, nil, false)
	} else {
		n.fsys.cache.InvalidatePath(rel)
	}
	return written, 0
}

func (n *firnFSNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	parentRel := n.relPath()
	childRel := joinFirnFSRel(parentRel, name)
	if n.fsys.isSyntheticCallerKind(ctx, childRel, syntheticCreate) {
		var attr fsAttrWire
		var ec syscall.Errno
		if cachedAttr, _, _, ok := n.fsys.cache.GetEntry(childRel); ok {
			attr, ec = cachedAttr, 0
		} else if childFull := n.fsys.backingPath(childRel); childFull != "" {
			attr, ec = lstatLinuxAttr(childFull)
		} else {
			attr, ec = n.fetchAttr(childRel)
		}
		if ec != 0 {
			return nil, nil, 0, ec
		}
		n.fsys.cache.InvalidatePath(childRel)
		n.fsys.cache.PutEntry(childRel, attr, nil, false)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := n.newChildNode(childRel)
		fh := &firnFSFileHandle{rel: childRel, fsys: n.fsys, synthetic: true}
		return n.NewInode(ctx, child, stableFromWire(attr)), fh, fuse.FOPEN_DIRECT_IO, 0
	}
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		oflags := os.O_CREATE | os.O_RDWR | (int(flags) & (syscall.O_EXCL | syscall.O_TRUNC | syscall.O_APPEND))
		if (flags & syscall.O_WRONLY) != 0 {
			oflags = os.O_CREATE | os.O_WRONLY | (int(flags) & (syscall.O_EXCL | syscall.O_TRUNC | syscall.O_APPEND))
		}
		perm := os.FileMode(mode & 0o7777)
		if perm == 0 {
			perm = 0o644
		}
		file, err := os.OpenFile(childFull, oflags, perm)
		if err != nil {
			return nil, nil, 0, errToErrno(err)
		}
		attr, ec := fstatLinuxAttr(int(file.Fd()))
		if ec != 0 {
			_ = file.Close()
			return nil, nil, 0, ec
		}
		n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := n.newChildNode(childRel)
		fh := &firnFSFileHandle{file: file, rel: childRel, fsys: n.fsys}
		return n.NewInode(ctx, child, stableFromWire(attr)), fh, 0, 0
	}

	var req bytes.Buffer
	writeShortStr(&req, childRel)
	var hdr [8]byte
	binary.BigEndian.PutUint32(hdr[0:4], mode)
	binary.BigEndian.PutUint32(hdr[4:8], flags)
	req.Write(hdr[:])

	resp, err := n.fsys.client.call(fsOpCreate, req.Bytes())
	if err != nil {
		return nil, nil, 0, syscall.EIO
	}
	ec, attr := decodeErrnoAndAttr(resp)
	if ec != 0 {
		return nil, nil, 0, ec
	}
	n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := n.newChildNode(childRel)
	return n.NewInode(ctx, child, stableFromWire(attr)), nil, 0, 0
}

func (n *firnFSNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	parentRel := n.relPath()
	childRel := joinFirnFSRel(parentRel, name)
	if n.fsys.isSyntheticCallerKind(ctx, childRel, syntheticMkdir) {
		var attr fsAttrWire
		var ec syscall.Errno
		if cachedAttr, _, _, ok := n.fsys.cache.GetEntry(childRel); ok {
			attr, ec = cachedAttr, 0
		} else if childFull := n.fsys.backingPath(childRel); childFull != "" {
			attr, ec = lstatLinuxAttr(childFull)
		} else {
			attr, ec = n.fetchAttr(childRel)
		}
		if ec != 0 {
			return nil, ec
		}
		n.fsys.markDir(childRel)
		n.fsys.cache.InvalidatePath(childRel)
		n.fsys.cache.PutEntry(childRel, attr, nil, false)
		n.fsys.cache.PutDirPrefetch(childRel, nil)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := n.newChildNode(childRel)
		return n.NewInode(ctx, child, stableFromWire(attr)), 0
	}
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		perm := os.FileMode(mode & 0o7777)
		if perm == 0 {
			perm = 0o755
		}
		if err := os.Mkdir(childFull, perm); err != nil {
			return nil, errToErrno(err)
		}
		attr, ec := lstatLinuxAttr(childFull)
		if ec != 0 {
			return nil, ec
		}
		n.fsys.markDir(childRel)
		n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
		n.fsys.cache.PutDirPrefetch(childRel, nil)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := n.newChildNode(childRel)
		return n.NewInode(ctx, child, stableFromWire(attr)), 0
	}

	var req bytes.Buffer
	writeShortStr(&req, childRel)
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], mode)
	req.Write(hdr[:])

	resp, err := n.fsys.client.call(fsOpMkdir, req.Bytes())
	if err != nil {
		return nil, syscall.EIO
	}
	ec, attr := decodeErrnoAndAttr(resp)
	if ec != 0 {
		return nil, ec
	}
	n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
	n.fsys.cache.PutDirPrefetch(childRel, nil)
	if attr.Mode&syscall.S_IFMT == syscall.S_IFDIR {
		n.fsys.markDir(childRel)
	}
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := n.newChildNode(childRel)
	return n.NewInode(ctx, child, stableFromWire(attr)), 0
}

func (n *firnFSNode) Unlink(ctx context.Context, name string) syscall.Errno {
	parentRel := n.relPath()
	childRel := joinFirnFSRel(parentRel, name)
	if n.fsys.isSyntheticCallerKind(ctx, childRel, syntheticDelete) {
		n.fsys.cache.InvalidatePath(childRel)
		return 0
	}
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		if err := syscall.Unlink(childFull); err != nil {
			return errToErrno(err)
		}
		n.fsys.cache.RecordLocalRemove(parentRel, name)
		return 0
	}

	var req bytes.Buffer
	writeShortStr(&req, childRel)
	resp, err := n.fsys.client.call(fsOpUnlink, req.Bytes())
	if err != nil || len(resp) < 4 {
		return syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec == 0 {
		n.fsys.cache.RecordLocalRemove(parentRel, name)
	}
	return ec
}

func (n *firnFSNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	parentRel := n.relPath()
	childRel := joinFirnFSRel(parentRel, name)
	if n.fsys.isSyntheticCallerKind(ctx, childRel, syntheticRmdir) {
		n.fsys.cache.InvalidatePath(childRel)
		return 0
	}
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		if err := syscall.Rmdir(childFull); err != nil {
			return errToErrno(err)
		}
		n.fsys.cache.RecordLocalRemove(parentRel, name)
		return 0
	}

	var req bytes.Buffer
	writeShortStr(&req, childRel)
	resp, err := n.fsys.client.call(fsOpRmdir, req.Bytes())
	if err != nil || len(resp) < 4 {
		return syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec == 0 {
		n.fsys.cache.RecordLocalRemove(parentRel, name)
	}
	return ec
}

func (n *firnFSNode) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	oldRel := joinFirnFSRel(n.relPath(), name)
	var npRel string
	if np, ok := newParent.(*firnFSNode); ok {
		npRel = np.relPath()
	} else {
		npRel = strings.TrimPrefix(filepath.ToSlash(newParent.EmbeddedInode().Path(n.Root())), "/")
		if npRel == "." {
			npRel = ""
		}
	}
	newRel := joinFirnFSRel(npRel, newName)

	if oldFull := n.fsys.backingPath(oldRel); oldFull != "" {
		newFull := n.fsys.backingPath(newRel)
		if err := os.Rename(oldFull, newFull); err != nil {
			return errToErrno(err)
		}
		n.fsys.renameEpoch.Add(1)
		n.fsys.cache.InvalidatePath(oldRel)
		n.fsys.cache.InvalidatePath(newRel)
		return 0
	}

	var req bytes.Buffer
	writeShortStr(&req, oldRel)
	writeShortStr(&req, newRel)
	resp, err := n.fsys.client.call(fsOpRename, req.Bytes())
	if err != nil || len(resp) < 4 {
		return syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec == 0 {
		n.fsys.renameEpoch.Add(1)
		n.fsys.cache.InvalidatePath(oldRel)
		n.fsys.cache.InvalidatePath(newRel)
	}
	return ec
}

func (n *firnFSNode) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	parentRel := n.relPath()
	childRel := joinFirnFSRel(parentRel, name)
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		if err := os.Symlink(target, childFull); err != nil {
			return nil, errToErrno(err)
		}
		attr, ec := lstatLinuxAttr(childFull)
		if ec != 0 {
			return nil, ec
		}
		n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := n.newChildNode(childRel)
		return n.NewInode(ctx, child, stableFromWire(attr)), 0
	}

	var req bytes.Buffer
	writeShortStr(&req, childRel)
	writeShortStr(&req, target)
	resp, err := n.fsys.client.call(fsOpSymlink, req.Bytes())
	if err != nil {
		return nil, syscall.EIO
	}
	ec, attr := decodeErrnoAndAttr(resp)
	if ec != 0 {
		return nil, ec
	}
	n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
	if attr.Mode&syscall.S_IFMT == syscall.S_IFDIR {
		n.fsys.markDir(childRel)
	}
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := n.newChildNode(childRel)
	return n.NewInode(ctx, child, stableFromWire(attr)), 0
}

func (n *firnFSNode) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	rel := n.relPath()
	if full := n.fsys.backingPath(rel); full != "" {
		target, err := os.Readlink(full)
		if err != nil {
			return nil, errToErrno(err)
		}
		return []byte(target), 0
	}

	var req bytes.Buffer
	writeShortStr(&req, rel)
	resp, err := n.fsys.client.call(fsOpReadlink, req.Bytes())
	if err != nil || len(resp) < 4 {
		return nil, syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec != 0 {
		return nil, ec
	}
	off := 4
	target, ok := readShortStr(resp, &off)
	if !ok {
		return nil, syscall.EIO
	}
	return []byte(target), 0
}

func (n *firnFSNode) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	var targetRel string
	if tn, ok := target.(*firnFSNode); ok {
		targetRel = tn.relPath()
	} else {
		targetRel = strings.TrimPrefix(filepath.ToSlash(target.EmbeddedInode().Path(n.Root())), "/")
	}
	parentRel := n.relPath()
	newRel := joinFirnFSRel(parentRel, name)
	if targetFull := n.fsys.backingPath(targetRel); targetFull != "" {
		newFull := n.fsys.backingPath(newRel)
		if err := os.Link(targetFull, newFull); err != nil {
			return nil, errToErrno(err)
		}
		attr, ec := lstatLinuxAttr(newFull)
		if ec != 0 {
			return nil, ec
		}
		n.fsys.cache.InvalidatePath(targetRel)
		n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
		fillFuseAttr(attr, &out.Attr)
		child := n.newChildNode(newRel)
		return n.NewInode(ctx, child, stableFromWire(attr)), 0
	}

	var req bytes.Buffer
	writeShortStr(&req, targetRel)
	writeShortStr(&req, newRel)
	resp, err := n.fsys.client.call(fsOpLink, req.Bytes())
	if err != nil {
		return nil, syscall.EIO
	}
	ec, attr := decodeErrnoAndAttr(resp)
	if ec != 0 {
		return nil, ec
	}
	n.fsys.cache.InvalidatePath(targetRel)
	n.fsys.cache.RecordLocalCreate(parentRel, name, attr)
	fillFuseAttr(attr, &out.Attr)
	child := n.newChildNode(newRel)
	return n.NewInode(ctx, child, stableFromWire(attr)), 0
}

func (n *firnFSNode) Fsync(ctx context.Context, f fs.FileHandle, flags uint32) syscall.Errno {
	if fh, ok := f.(*firnFSFileHandle); ok {
		return fh.Fsync(ctx, flags)
	}
	if full := n.fsys.backingPath(n.relPath()); full != "" {
		file, err := os.Open(full)
		if err != nil {
			return errToErrno(err)
		}
		err = file.Sync()
		_ = file.Close()
		return errToErrno(err)
	}

	var req bytes.Buffer
	writeShortStr(&req, n.relPath())
	resp, err := n.fsys.client.call(fsOpFsync, req.Bytes())
	if err != nil || len(resp) < 4 {
		return syscall.EIO
	}
	return syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
}

func (n *firnFSNode) Statfs(ctx context.Context, out *fuse.StatfsOut) syscall.Errno {
	if full := n.fsys.backingPath(""); full != "" {
		var st syscall.Statfs_t
		if err := syscall.Statfs(full, &st); err == nil {
			out.Blocks = st.Blocks
			out.Bfree = st.Bfree
			out.Bavail = st.Bavail
			out.Files = st.Files
			out.Ffree = st.Ffree
			out.Bsize = uint32(st.Bsize)
			out.Frsize = uint32(st.Bsize)
			out.NameLen = 255
			return 0
		}
	}

	resp, err := n.fsys.client.call(fsOpStatfs, nil)
	if err != nil || len(resp) < 4 {
		return syscall.EIO
	}
	ec := syscall.Errno(binary.BigEndian.Uint32(resp[0:4]))
	if ec != 0 {
		return ec
	}
	if len(resp) < 52 {
		return syscall.EIO
	}
	out.Blocks = binary.BigEndian.Uint64(resp[4:12])
	out.Bfree = binary.BigEndian.Uint64(resp[12:20])
	out.Bavail = binary.BigEndian.Uint64(resp[20:28])
	out.Files = binary.BigEndian.Uint64(resp[28:36])
	out.Ffree = binary.BigEndian.Uint64(resp[36:44])
	out.Bsize = binary.BigEndian.Uint32(resp[44:48])
	out.Frsize = binary.BigEndian.Uint32(resp[48:52])
	out.NameLen = 255
	return 0
}
