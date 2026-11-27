package main

import (
	"bytes"
	"container/list"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	fsOpGetattr        byte = 1
	fsOpLookup         byte = 2
	fsOpReaddirPref    byte = 3
	fsOpRead           byte = 4
	fsOpWrite          byte = 5
	fsOpCreate         byte = 6
	fsOpMkdir          byte = 7
	fsOpUnlink         byte = 8
	fsOpRmdir          byte = 9
	fsOpRename         byte = 10
	fsOpSetattr        byte = 11
	fsOpFsync          byte = 12
	fsOpSymlink        byte = 13
	fsOpReadlink       byte = 14
	fsOpLink           byte = 15
	fsOpStatfs         byte = 16
	fsOpPushInvalidate byte = 0x80
	fsOpPushPrefetch   byte = 0x81

	firnFSCacheMaxBytes   = 64 * 1024 * 1024
	firnFSCacheMaxEntries = 16384
	firnLocalEchoWindowNs = int64(150 * time.Millisecond)
)

type fsAttrWire struct {
	Ino     uint64
	Size    uint64
	Blocks  uint64
	AtimeNs int64
	MtimeNs int64
	CtimeNs int64
	Mode    uint32
	Nlink   uint32
	UID     uint32
	GID     uint32
}

type fsDirPrefetchItem struct {
	Name    string
	Attr    fsAttrWire
	HasData bool
	Data    []byte
}

type fsStatfsWire struct {
	Blocks uint64
	Bfree  uint64
	Bavail uint64
	Files  uint64
	Ffree  uint64
	Bsize  uint32
	Frsize uint32
}

func cleanFirnFSRelPath(rel string) string {
	rel = strings.TrimPrefix(filepath.ToSlash(filepath.Clean("/"+rel)), "/")
	if rel == "." {
		return ""
	}
	return rel
}

func cleanFastRelPath(rel string) string {
	if rel == "" {
		return ""
	}
	if rel[0] != '/' && rel[len(rel)-1] != '/' && rel != "." &&
		!strings.Contains(rel, "//") && !strings.Contains(rel, "..") && !strings.Contains(rel, "\\") {
		return rel
	}
	return cleanFirnFSRelPath(rel)
}

func parentOfFirnFSRel(rel string) string {
	if idx := strings.LastIndex(rel, "/"); idx > 0 {
		return rel[:idx]
	}
	return ""
}

func joinFirnFSRel(dir, name string) string {
	if dir == "" {
		return name
	}
	return dir + "/" + name
}

func writeShortStr(buf *bytes.Buffer, s string) {
	var hdr [2]byte
	b := []byte(s)
	if len(b) > 65535 {
		b = b[:65535]
	}
	binary.BigEndian.PutUint16(hdr[:], uint16(len(b)))
	buf.Write(hdr[:])
	buf.Write(b)
}

func readShortStr(data []byte, off *int) (string, bool) {
	if *off+2 > len(data) {
		return "", false
	}
	n := int(binary.BigEndian.Uint16(data[*off : *off+2]))
	*off += 2
	if *off+n > len(data) {
		return "", false
	}
	s := string(data[*off : *off+n])
	*off += n
	return s, true
}

func decodeFSAttr(data []byte, off *int) (fsAttrWire, bool) {
	if *off+64 > len(data) {
		return fsAttrWire{}, false
	}
	b := data[*off : *off+64]
	*off += 64
	return fsAttrWire{
		Ino:     binary.BigEndian.Uint64(b[0:8]),
		Size:    binary.BigEndian.Uint64(b[8:16]),
		Blocks:  binary.BigEndian.Uint64(b[16:24]),
		AtimeNs: int64(binary.BigEndian.Uint64(b[24:32])),
		MtimeNs: int64(binary.BigEndian.Uint64(b[32:40])),
		CtimeNs: int64(binary.BigEndian.Uint64(b[40:48])),
		Mode:    binary.BigEndian.Uint32(b[48:52]),
		Nlink:   binary.BigEndian.Uint32(b[52:56]),
		UID:     binary.BigEndian.Uint32(b[56:60]),
		GID:     binary.BigEndian.Uint32(b[60:64]),
	}, true
}

// decodeDirPrefetchItems decodes cnt serialized prefetch entries starting at *off.
// Data slices point into data when copyData is false; callers storing directly into
// long-lived buffers can set copyData=true or rely on PutDirPrefetch copying.
func decodeDirPrefetchItems(data []byte, off *int, cnt int, copyData bool) ([]fsDirPrefetchItem, bool) {
	if cnt < 0 || cnt > 65536 {
		return nil, false
	}
	items := make([]fsDirPrefetchItem, 0, cnt)
	for i := 0; i < cnt; i++ {
		name, ok1 := readShortStr(data, off)
		attr, ok2 := decodeFSAttr(data, off)
		if !ok1 || !ok2 || *off >= len(data) {
			return nil, false
		}
		hasData := data[*off] != 0
		*off++
		var fileData []byte
		if hasData {
			if *off+4 > len(data) {
				return nil, false
			}
			dlen := int(binary.BigEndian.Uint32(data[*off : *off+4]))
			*off += 4
			if dlen < 0 || *off+dlen > len(data) {
				return nil, false
			}
			if copyData {
				fileData = append([]byte(nil), data[*off:*off+dlen]...)
			} else {
				fileData = data[*off : *off+dlen]
			}
			*off += dlen
		}
		items = append(items, fsDirPrefetchItem{
			Name:    name,
			Attr:    attr,
			HasData: hasData,
			Data:    fileData,
		})
	}
	return items, true
}

type cachedFSEntry struct {
	rel     string
	attr    fsAttrWire
	hasData bool
	data    []byte
	elem    *list.Element
}

type cachedFSDir struct {
	items   []string
	nameIdx map[string]int
}

type firnFSCache struct {
	mu               sync.RWMutex
	maxBytes         int
	maxEntries       int
	curBytes         int
	entries          map[string]*cachedFSEntry
	dirs             map[string]cachedFSDir
	childrenByParent map[string]map[string]struct{}
	recentLocalMut   map[string]int64
	lru              *list.List
}

func newFirnFSCache(maxBytes, maxEntries int) *firnFSCache {
	if maxBytes <= 0 {
		maxBytes = firnFSCacheMaxBytes
	}
	if maxEntries <= 0 {
		maxEntries = firnFSCacheMaxEntries
	}
	return &firnFSCache{
		maxBytes:         maxBytes,
		maxEntries:       maxEntries,
		entries:          make(map[string]*cachedFSEntry),
		dirs:             make(map[string]cachedFSDir),
		childrenByParent: make(map[string]map[string]struct{}),
		recentLocalMut:   make(map[string]int64),
		lru:              list.New(),
	}
}

func (c *firnFSCache) recordLocalMutationLocked(rel string, nowNs int64) {
	if rel == "" {
		return
	}
	c.recentLocalMut[rel] = nowNs
	if len(c.recentLocalMut) > 4096 {
		cutoff := nowNs - int64(500*time.Millisecond)
		for k, ts := range c.recentLocalMut {
			if ts < cutoff {
				delete(c.recentLocalMut, k)
			}
		}
	}
}

func (c *firnFSCache) IsRecentLocalEcho(rel string, nowNs int64) bool {
	rel = cleanFastRelPath(rel)
	c.mu.RLock()
	ts, ok := c.recentLocalMut[rel]
	c.mu.RUnlock()
	if !ok {
		return false
	}
	return nowNs >= ts && (nowNs-ts) <= firnLocalEchoWindowNs
}

func (c *firnFSCache) trackChildLocked(rel string) {
	if rel == "" {
		return
	}
	parent := parentOfFirnFSRel(rel)
	set := c.childrenByParent[parent]
	if set == nil {
		set = make(map[string]struct{})
		c.childrenByParent[parent] = set
	}
	set[rel] = struct{}{}
}

func (c *firnFSCache) untrackChildIfGoneLocked(rel string) {
	if rel == "" {
		return
	}
	if _, inEnt := c.entries[rel]; inEnt {
		return
	}
	if _, inDir := c.dirs[rel]; inDir {
		return
	}
	parent := parentOfFirnFSRel(rel)
	if set, ok := c.childrenByParent[parent]; ok {
		delete(set, rel)
		if len(set) == 0 {
			delete(c.childrenByParent, parent)
		}
	}
}

func (c *firnFSCache) GetEntry(rel string) (fsAttrWire, []byte, bool, bool) {
	rel = cleanFastRelPath(rel)
	c.mu.RLock()
	defer c.mu.RUnlock()
	ent, ok := c.entries[rel]
	if !ok {
		return fsAttrWire{}, nil, false, false
	}
	return ent.attr, ent.data, ent.hasData, true
}

func (c *firnFSCache) PutEntry(rel string, attr fsAttrWire, data []byte, hasData bool) {
	rel = cleanFastRelPath(rel)
	var copied []byte
	if hasData && data != nil {
		copied = append([]byte(nil), data...)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.putEntryOwnedLocked(rel, attr, copied, hasData)
}

func (c *firnFSCache) putEntryOwnedLocked(rel string, attr fsAttrWire, ownedData []byte, hasData bool) {
	if existing, ok := c.entries[rel]; ok {
		c.curBytes -= len(existing.data)
		existing.attr = attr
		existing.data = ownedData
		existing.hasData = hasData
		c.curBytes += len(ownedData)
		c.lru.MoveToFront(existing.elem)
	} else {
		ent := &cachedFSEntry{
			rel:     rel,
			attr:    attr,
			hasData: hasData,
			data:    ownedData,
		}
		ent.elem = c.lru.PushFront(ent)
		c.entries[rel] = ent
		c.curBytes += len(ownedData)
		c.trackChildLocked(rel)
	}
	c.evictLocked()
}

func (c *firnFSCache) evictLocked() {
	for c.lru.Len() > c.maxEntries || c.curBytes > c.maxBytes {
		tail := c.lru.Back()
		if tail == nil {
			break
		}
		ent := tail.Value.(*cachedFSEntry)
		c.lru.Remove(tail)
		delete(c.entries, ent.rel)
		c.curBytes -= len(ent.data)
		c.untrackChildIfGoneLocked(ent.rel)
	}
}

func (c *firnFSCache) PutDirPrefetch(dirRel string, items []fsDirPrefetchItem) {
	dirRel = cleanFastRelPath(dirRel)
	names := make([]string, 0, len(items))
	nameIdx := make(map[string]int, len(items))
	copiedData := make([][]byte, len(items))
	for i, it := range items {
		if it.HasData && it.Data != nil {
			copiedData[i] = append([]byte(nil), it.Data...)
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for i, it := range items {
		if _, dup := nameIdx[it.Name]; !dup {
			nameIdx[it.Name] = len(names)
			names = append(names, it.Name)
		}
		childRel := joinFirnFSRel(dirRel, it.Name)
		c.putEntryOwnedLocked(childRel, it.Attr, copiedData[i], it.HasData)
	}
	c.dirs[dirRel] = cachedFSDir{items: names, nameIdx: nameIdx}
	c.trackChildLocked(dirRel)
}

func (c *firnFSCache) GetDirPrefetch(dirRel string) ([]fsDirPrefetchItem, bool) {
	dirRel = cleanFastRelPath(dirRel)
	c.mu.RLock()
	defer c.mu.RUnlock()
	dir, ok := c.dirs[dirRel]
	if !ok {
		return nil, false
	}
	out := make([]fsDirPrefetchItem, 0, len(dir.items))
	for _, name := range dir.items {
		childRel := joinFirnFSRel(dirRel, name)
		ent, exists := c.entries[childRel]
		if !exists {
			return nil, false
		}
		out = append(out, fsDirPrefetchItem{
			Name:    name,
			Attr:    ent.attr,
			HasData: ent.hasData,
			Data:    ent.data,
		})
	}
	return out, true
}

func (c *firnFSCache) IsKnownAbsent(parentRel, name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	parentRel = cleanFastRelPath(parentRel)
	c.mu.RLock()
	defer c.mu.RUnlock()
	dir, ok := c.dirs[parentRel]
	if !ok {
		return false
	}
	_, exists := dir.nameIdx[name]
	return !exists
}

func (c *firnFSCache) RecordLocalCreate(parentRel, name string, attr fsAttrWire) {
	parentRel = cleanFastRelPath(parentRel)
	childRel := joinFirnFSRel(parentRel, name)
	nowNs := time.Now().UnixNano()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.putEntryOwnedLocked(childRel, attr, nil, false)
	c.recordLocalMutationLocked(childRel, nowNs)
	if dir, ok := c.dirs[parentRel]; ok {
		if _, exists := dir.nameIdx[name]; !exists {
			if dir.nameIdx == nil {
				dir.nameIdx = make(map[string]int)
			}
			dir.nameIdx[name] = len(dir.items)
			dir.items = append(dir.items, name)
			c.dirs[parentRel] = dir
		}
	}
}

func (c *firnFSCache) RecordLocalRemove(parentRel, name string) {
	parentRel = cleanFastRelPath(parentRel)
	childRel := joinFirnFSRel(parentRel, name)
	nowNs := time.Now().UnixNano()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.removeSubtreeLocked(childRel)
	c.recordLocalMutationLocked(childRel, nowNs)
	if dir, ok := c.dirs[parentRel]; ok {
		if idx, exists := dir.nameIdx[name]; exists {
			lastIdx := len(dir.items) - 1
			if idx != lastIdx {
				moved := dir.items[lastIdx]
				dir.items[idx] = moved
				dir.nameIdx[moved] = idx
			}
			dir.items = dir.items[:lastIdx]
			delete(dir.nameIdx, name)
			c.dirs[parentRel] = dir
		}
	}
}

func (c *firnFSCache) UpdateWriteAttr(rel string, minSize uint64, mtimeNs int64) {
	rel = cleanFastRelPath(rel)
	nowNs := time.Now().UnixNano()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.recordLocalMutationLocked(rel, nowNs)
	if ent, ok := c.entries[rel]; ok {
		c.curBytes -= len(ent.data)
		ent.data = nil
		ent.hasData = false
		if minSize > ent.attr.Size {
			ent.attr.Size = minSize
		}
		ent.attr.MtimeNs = mtimeNs
	}
}

func (c *firnFSCache) InvalidatePath(rel string) {
	rel = cleanFastRelPath(rel)
	c.mu.Lock()
	defer c.mu.Unlock()
	if rel == "" {
		c.curBytes = 0
		c.entries = make(map[string]*cachedFSEntry)
		c.dirs = make(map[string]cachedFSDir)
		c.childrenByParent = make(map[string]map[string]struct{})
		c.lru.Init()
		return
	}
	parent := parentOfFirnFSRel(rel)
	delete(c.dirs, parent)
	c.untrackChildIfGoneLocked(parent)
	c.removeSubtreeLocked(rel)
}

func (c *firnFSCache) removeSubtreeLocked(rootRel string) {
	stack := []string{rootRel}
	for len(stack) > 0 {
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		c.removeEntryLocked(cur)
		if _, hadDir := c.dirs[cur]; hadDir {
			delete(c.dirs, cur)
			c.untrackChildIfGoneLocked(cur)
		}
		if kids, ok := c.childrenByParent[cur]; ok {
			for k := range kids {
				stack = append(stack, k)
			}
			delete(c.childrenByParent, cur)
		}
	}
}

func (c *firnFSCache) removeEntryLocked(rel string) {
	if ent, ok := c.entries[rel]; ok {
		c.curBytes -= len(ent.data)
		c.lru.Remove(ent.elem)
		delete(c.entries, rel)
		c.untrackChildIfGoneLocked(rel)
	}
}

func (c *firnFSCache) Stats() (entries int, bytes int, dirs int) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries), c.curBytes, len(c.dirs)
}

type firnFSClient struct {
	addr         string
	dialer       func() (net.Conn, error)
	onInvalidate func([]string)
	onPrefetch   func(string, []fsDirPrefetchItem)

	mu        sync.Mutex
	conn      net.Conn
	writeMu   sync.Mutex
	pending   map[uint32]chan []byte
	nextReqID atomic.Uint32
	closed    bool
}

func (c *firnFSClient) SetOnPrefetch(fn func(dirRel string, items []fsDirPrefetchItem)) {
	c.mu.Lock()
	c.onPrefetch = fn
	c.mu.Unlock()
}

func newFirnFSClient(addr string, onInvalidate func([]string)) *firnFSClient {
	return newFirnFSClientWithDialer(addr, func() (net.Conn, error) {
		c, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			return nil, err
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
			_ = tc.SetReadBuffer(4 << 20)
			_ = tc.SetWriteBuffer(4 << 20)
		}
		return c, nil
	}, onInvalidate)
}

func newFirnFSClientWithDialer(addr string, dialFn func() (net.Conn, error), onInvalidate func([]string)) *firnFSClient {
	return &firnFSClient{
		addr:         addr,
		onInvalidate: onInvalidate,
		pending:      make(map[uint32]chan []byte),
		dialer:       dialFn,
	}
}

func newFirnFSClientWithConn(conn net.Conn, onInvalidate func([]string)) *firnFSClient {
	cl := &firnFSClient{
		conn:         conn,
		onInvalidate: onInvalidate,
		pending:      make(map[uint32]chan []byte),
	}
	go cl.readLoop(conn)
	return cl
}

func (c *firnFSClient) ensureConn() (net.Conn, error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, errors.New("firnfs client closed")
	}
	if c.conn != nil {
		conn := c.conn
		c.mu.Unlock()
		return conn, nil
	}
	dialFn := c.dialer
	c.mu.Unlock()

	if dialFn == nil {
		return nil, errors.New("firnfs disconnected")
	}
	conn, err := dialFn()
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		_ = conn.Close()
		return nil, errors.New("firnfs client closed")
	}
	if c.conn != nil {
		existing := c.conn
		c.mu.Unlock()
		_ = conn.Close()
		return existing, nil
	}
	c.conn = conn
	c.mu.Unlock()
	go c.readLoop(conn)
	return conn, nil
}

func (c *firnFSClient) readLoop(conn net.Conn) {
	defer func() {
		_ = conn.Close()
		c.mu.Lock()
		if c.conn == conn {
			c.conn = nil
		}
		for id, ch := range c.pending {
			close(ch)
			delete(c.pending, id)
		}
		c.mu.Unlock()
	}()

	var hdr [9]byte
	for {
		if _, err := io.ReadFull(conn, hdr[:]); err != nil {
			return
		}
		reqID := binary.BigEndian.Uint32(hdr[0:4])
		op := hdr[4]
		plen := binary.BigEndian.Uint32(hdr[5:9])
		if plen > 32*1024*1024 {
			return
		}
		payload := make([]byte, plen)
		if plen > 0 {
			if _, err := io.ReadFull(conn, payload); err != nil {
				return
			}
		}
		if reqID == 0 && op == fsOpPushInvalidate {
			if c.onInvalidate != nil {
				paths := decodeInvalidationPayload(payload)
				if len(paths) > 0 {
					go c.onInvalidate(paths)
				}
			}
			continue
		}
		if reqID == 0 && op == fsOpPushPrefetch {
			c.mu.Lock()
			fn := c.onPrefetch
			c.mu.Unlock()
			if fn != nil {
				off := 0
				dirRel, ok1 := readShortStr(payload, &off)
				if ok1 && off+4 <= len(payload) {
					cnt := int(binary.BigEndian.Uint32(payload[off : off+4]))
					off += 4
					if items, ok2 := decodeDirPrefetchItems(payload, &off, cnt, false); ok2 {
						fn(dirRel, items)
					}
				}
			}
			continue
		}
		c.mu.Lock()
		ch := c.pending[reqID]
		if ch != nil {
			delete(c.pending, reqID)
		}
		c.mu.Unlock()
		if ch != nil {
			ch <- payload
			close(ch)
		}
	}
}

func decodeInvalidationPayload(payload []byte) []string {
	if len(payload) < 2 {
		return nil
	}
	cnt := int(binary.BigEndian.Uint16(payload[0:2]))
	off := 2
	out := make([]string, 0, cnt)
	for i := 0; i < cnt; i++ {
		s, ok := readShortStr(payload, &off)
		if !ok {
			break
		}
		out = append(out, s)
	}
	return out
}

func (c *firnFSClient) call(op byte, reqPayload []byte) ([]byte, error) {
	conn, err := c.ensureConn()
	if err != nil {
		return nil, err
	}
	reqID := c.nextReqID.Add(1)
	if reqID == 0 {
		reqID = c.nextReqID.Add(1)
	}
	ch := make(chan []byte, 1)
	c.mu.Lock()
	c.pending[reqID] = ch
	c.mu.Unlock()

	frame := make([]byte, 9+len(reqPayload))
	binary.BigEndian.PutUint32(frame[0:4], reqID)
	frame[4] = op
	binary.BigEndian.PutUint32(frame[5:9], uint32(len(reqPayload)))
	if len(reqPayload) > 0 {
		copy(frame[9:], reqPayload)
	}

	c.writeMu.Lock()
	_, werr := conn.Write(frame)
	c.writeMu.Unlock()
	if werr != nil {
		c.mu.Lock()
		delete(c.pending, reqID)
		c.mu.Unlock()
		return nil, werr
	}

	select {
	case resp, ok := <-ch:
		if !ok {
			return nil, errors.New("firnfs connection reset")
		}
		return resp, nil
	case <-time.After(15 * time.Second):
		c.mu.Lock()
		delete(c.pending, reqID)
		c.mu.Unlock()
		return nil, errors.New("firnfs request timeout")
	}
}

func (c *firnFSClient) Close() {
	c.mu.Lock()
	c.closed = true
	conn := c.conn
	c.conn = nil
	c.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}
