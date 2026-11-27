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
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

type firnFSMount struct {
	server     *fuse.Server
	client     *firnFSClient
	root       *firnFSNode
	cache      *firnFSCache
	backingDir string
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

func startFirnFS(mountPoint, hostAddr string) (*firnFSMount, error) {
	_ = syscall.Unmount(mountPoint, syscall.MNT_DETACH)
	if err := os.MkdirAll(mountPoint, 0o755); err != nil {
		return nil, err
	}
	cache := newFirnFSCache(firnFSCacheMaxBytes, firnFSCacheMaxEntries)
	backing := detectVirtioFSBacking()
	mountObj := &firnFSMount{
		cache:      cache,
		backingDir: backing,
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
		for _, raw := range paths {
			rel := cleanFirnFSRelPath(raw)
			cache.InvalidatePath(rel)
			if rootNode != nil {
				mountObj.notifyKernelInvalidate(rel)
			}
		}
	})
	if _, err := client.ensureConn(); err != nil {
		client.Close()
		return nil, err
	}
	mountObj.client = client

	rootNode = &firnFSNode{fsys: mountObj}
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
	log.Printf("[firn-guestd] firnfs mounted at %s -> vsock:2385/%s (backing=%q, cache 64MiB + FSEvents)", mountPoint, hostAddr, backing)
	return mountObj, nil
}

func (m *firnFSMount) Unmount() {
	if m.server != nil {
		_ = m.server.Unmount()
	}
	if m.client != nil {
		m.client.Close()
	}
}

func (m *firnFSMount) notifyKernelInvalidate(rel string) {
	rootInode := &m.root.Inode
	if rel == "" {
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

func lstatLinuxAttr(fullPath string) (fsAttrWire, syscall.Errno) {
	var st syscall.Stat_t
	if err := syscall.Lstat(fullPath, &st); err != nil {
		return fsAttrWire{}, errToErrno(err)
	}
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
	}, 0
}

type firnFSFileHandle struct {
	mu   sync.Mutex
	file *os.File
	rel  string
	fsys *firnFSMount
}

var (
	_ = (fs.FileReader)((*firnFSFileHandle)(nil))
	_ = (fs.FileWriter)((*firnFSFileHandle)(nil))
	_ = (fs.FileFsyncer)((*firnFSFileHandle)(nil))
	_ = (fs.FileReleaser)((*firnFSFileHandle)(nil))
)

func (h *firnFSFileHandle) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
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
	h.mu.Lock()
	f := h.file
	h.mu.Unlock()
	if f == nil {
		return 0, syscall.EBADF
	}
	n, err := f.WriteAt(data, off)
	h.fsys.cache.InvalidatePath(h.rel)
	if err != nil {
		return uint32(n), errToErrno(err)
	}
	return uint32(n), 0
}

func (h *firnFSFileHandle) Fsync(ctx context.Context, flags uint32) syscall.Errno {
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
	err := f.Close()
	if full := h.fsys.backingPath(h.rel); full != "" {
		if attr, ec := lstatLinuxAttr(full); ec == 0 {
			h.fsys.cache.PutEntry(h.rel, attr, nil, false)
		}
	}
	return errToErrno(err)
}

type firnFSNode struct {
	fs.Inode
	fsys *firnFSMount
}

var (
	_ = (fs.NodeLookuper)((*firnFSNode)(nil))
	_ = (fs.NodeGetattrer)((*firnFSNode)(nil))
	_ = (fs.NodeSetattrer)((*firnFSNode)(nil))
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

func (n *firnFSNode) relPath() string {
	p := n.Path(n.Root())
	if p == "" || p == "." {
		return ""
	}
	return strings.TrimPrefix(filepath.ToSlash(p), "/")
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
	childRel := joinFirnFSRel(n.relPath(), name)
	attr, ec := n.fetchAttr(childRel)
	if ec != 0 {
		return nil, ec
	}
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := &firnFSNode{fsys: n.fsys}
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

func (n *firnFSNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
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
		return fs.NewListDirStream(entries), 0
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
	items := make([]fsDirPrefetchItem, 0, cnt)
	entries := make([]fuse.DirEntry, 0, cnt)
	for i := 0; i < cnt; i++ {
		name, ok1 := readShortStr(resp, &off)
		attr, ok2 := decodeFSAttr(resp, &off)
		if !ok1 || !ok2 || off >= len(resp) {
			return nil, syscall.EIO
		}
		hasData := resp[off] != 0
		off++
		var data []byte
		if hasData {
			if off+4 > len(resp) {
				return nil, syscall.EIO
			}
			dlen := int(binary.BigEndian.Uint32(resp[off : off+4]))
			off += 4
			if off+dlen > len(resp) {
				return nil, syscall.EIO
			}
			data = append([]byte(nil), resp[off:off+dlen]...)
			off += dlen
		}
		items = append(items, fsDirPrefetchItem{Name: name, Attr: attr, HasData: hasData, Data: data})
		entries = append(entries, fuse.DirEntry{
			Mode: attr.Mode & syscall.S_IFMT,
			Name: name,
			Ino:  attr.Ino,
		})
	}
	n.fsys.cache.PutDirPrefetch(rel, items)
	return fs.NewListDirStream(entries), 0
}

func (n *firnFSNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	if (flags & (syscall.O_WRONLY | syscall.O_RDWR | syscall.O_TRUNC | syscall.O_APPEND)) == 0 {
		return nil, fuse.FOPEN_KEEP_CACHE, 0
	}
	rel := n.relPath()
	if full := n.fsys.backingPath(rel); full != "" {
		oflags := int(flags) &^ (syscall.O_CREAT | syscall.O_EXCL)
		f, err := os.OpenFile(full, oflags, 0)
		if err != nil {
			return nil, 0, errToErrno(err)
		}
		n.fsys.cache.InvalidatePath(rel)
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
		n.fsys.cache.InvalidatePath(rel)
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
		attr, ec := lstatLinuxAttr(childFull)
		if ec != 0 {
			_ = file.Close()
			return nil, nil, 0, ec
		}
		n.fsys.cache.InvalidatePath(childRel)
		n.fsys.cache.PutEntry(childRel, attr, nil, false)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := &firnFSNode{fsys: n.fsys}
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
	n.fsys.cache.InvalidatePath(childRel)
	n.fsys.cache.PutEntry(childRel, attr, nil, false)
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := &firnFSNode{fsys: n.fsys}
	return n.NewInode(ctx, child, stableFromWire(attr)), nil, 0, 0
}

func (n *firnFSNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childRel := joinFirnFSRel(n.relPath(), name)
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
		n.fsys.cache.InvalidatePath(childRel)
		n.fsys.cache.PutEntry(childRel, attr, nil, false)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := &firnFSNode{fsys: n.fsys}
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
	n.fsys.cache.InvalidatePath(childRel)
	n.fsys.cache.PutEntry(childRel, attr, nil, false)
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := &firnFSNode{fsys: n.fsys}
	return n.NewInode(ctx, child, stableFromWire(attr)), 0
}

func (n *firnFSNode) Unlink(ctx context.Context, name string) syscall.Errno {
	childRel := joinFirnFSRel(n.relPath(), name)
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		if err := syscall.Unlink(childFull); err != nil {
			return errToErrno(err)
		}
		n.fsys.cache.InvalidatePath(childRel)
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
		n.fsys.cache.InvalidatePath(childRel)
	}
	return ec
}

func (n *firnFSNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	childRel := joinFirnFSRel(n.relPath(), name)
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		if err := syscall.Rmdir(childFull); err != nil {
			return errToErrno(err)
		}
		n.fsys.cache.InvalidatePath(childRel)
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
		n.fsys.cache.InvalidatePath(childRel)
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
		n.fsys.cache.InvalidatePath(oldRel)
		n.fsys.cache.InvalidatePath(newRel)
	}
	return ec
}

func (n *firnFSNode) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childRel := joinFirnFSRel(n.relPath(), name)
	if childFull := n.fsys.backingPath(childRel); childFull != "" {
		if err := os.Symlink(target, childFull); err != nil {
			return nil, errToErrno(err)
		}
		attr, ec := lstatLinuxAttr(childFull)
		if ec != 0 {
			return nil, ec
		}
		n.fsys.cache.InvalidatePath(childRel)
		n.fsys.cache.PutEntry(childRel, attr, nil, false)
		fillFuseAttr(attr, &out.Attr)
		out.SetEntryTimeout(60 * time.Second)
		out.SetAttrTimeout(60 * time.Second)
		child := &firnFSNode{fsys: n.fsys}
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
	n.fsys.cache.InvalidatePath(childRel)
	n.fsys.cache.PutEntry(childRel, attr, nil, false)
	fillFuseAttr(attr, &out.Attr)
	out.SetEntryTimeout(60 * time.Second)
	out.SetAttrTimeout(60 * time.Second)
	child := &firnFSNode{fsys: n.fsys}
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
	newRel := joinFirnFSRel(n.relPath(), name)
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
		n.fsys.cache.InvalidatePath(newRel)
		fillFuseAttr(attr, &out.Attr)
		child := &firnFSNode{fsys: n.fsys}
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
	n.fsys.cache.InvalidatePath(newRel)
	fillFuseAttr(attr, &out.Attr)
	child := &firnFSNode{fsys: n.fsys}
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
