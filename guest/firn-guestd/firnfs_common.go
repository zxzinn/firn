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

	firnFSCacheMaxBytes   = 64 * 1024 * 1024
	firnFSCacheMaxEntries = 16384
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

type cachedFSEntry struct {
	rel     string
	attr    fsAttrWire
	hasData bool
	data    []byte
	elem    *list.Element
}

type cachedFSDir struct {
	items []string
}

type firnFSCache struct {
	mu         sync.RWMutex
	maxBytes   int
	maxEntries int
	curBytes   int
	entries    map[string]*cachedFSEntry
	dirs       map[string]cachedFSDir
	lru        *list.List
}

func newFirnFSCache(maxBytes, maxEntries int) *firnFSCache {
	if maxBytes <= 0 {
		maxBytes = firnFSCacheMaxBytes
	}
	if maxEntries <= 0 {
		maxEntries = firnFSCacheMaxEntries
	}
	return &firnFSCache{
		maxBytes:   maxBytes,
		maxEntries: maxEntries,
		entries:    make(map[string]*cachedFSEntry),
		dirs:       make(map[string]cachedFSDir),
		lru:        list.New(),
	}
}

func (c *firnFSCache) GetEntry(rel string) (fsAttrWire, []byte, bool, bool) {
	rel = cleanFirnFSRelPath(rel)
	c.mu.Lock()
	defer c.mu.Unlock()
	ent, ok := c.entries[rel]
	if !ok {
		return fsAttrWire{}, nil, false, false
	}
	c.lru.MoveToFront(ent.elem)
	return ent.attr, ent.data, ent.hasData, true
}

func (c *firnFSCache) PutEntry(rel string, attr fsAttrWire, data []byte, hasData bool) {
	rel = cleanFirnFSRelPath(rel)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.putEntryLocked(rel, attr, data, hasData)
}

func (c *firnFSCache) putEntryLocked(rel string, attr fsAttrWire, data []byte, hasData bool) {
	var copied []byte
	if hasData && data != nil {
		copied = append([]byte(nil), data...)
	}
	if existing, ok := c.entries[rel]; ok {
		c.curBytes -= len(existing.data)
		existing.attr = attr
		existing.data = copied
		existing.hasData = hasData
		c.curBytes += len(copied)
		c.lru.MoveToFront(existing.elem)
	} else {
		ent := &cachedFSEntry{
			rel:     rel,
			attr:    attr,
			hasData: hasData,
			data:    copied,
		}
		ent.elem = c.lru.PushFront(ent)
		c.entries[rel] = ent
		c.curBytes += len(copied)
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
	}
}

func (c *firnFSCache) PutDirPrefetch(dirRel string, items []fsDirPrefetchItem) {
	dirRel = cleanFirnFSRelPath(dirRel)
	names := make([]string, 0, len(items))
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, it := range items {
		names = append(names, it.Name)
		childRel := joinFirnFSRel(dirRel, it.Name)
		c.putEntryLocked(childRel, it.Attr, it.Data, it.HasData)
	}
	c.dirs[dirRel] = cachedFSDir{items: names}
}

func (c *firnFSCache) GetDirPrefetch(dirRel string) ([]fsDirPrefetchItem, bool) {
	dirRel = cleanFirnFSRelPath(dirRel)
	c.mu.Lock()
	defer c.mu.Unlock()
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
		c.lru.MoveToFront(ent.elem)
		out = append(out, fsDirPrefetchItem{
			Name:    name,
			Attr:    ent.attr,
			HasData: ent.hasData,
			Data:    ent.data,
		})
	}
	return out, true
}

func (c *firnFSCache) InvalidatePath(rel string) {
	rel = cleanFirnFSRelPath(rel)
	parent := ""
	if idx := strings.LastIndex(rel, "/"); idx > 0 {
		parent = rel[:idx]
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.removeEntryLocked(rel)
	delete(c.dirs, rel)
	if rel != "" {
		delete(c.dirs, parent)
		prefix := rel + "/"
		for k := range c.entries {
			if strings.HasPrefix(k, prefix) {
				c.removeEntryLocked(k)
			}
		}
		for k := range c.dirs {
			if strings.HasPrefix(k, prefix) {
				delete(c.dirs, k)
			}
		}
	} else {
		for k := range c.dirs {
			delete(c.dirs, k)
		}
		for k := range c.entries {
			c.removeEntryLocked(k)
		}
	}
}

func (c *firnFSCache) removeEntryLocked(rel string) {
	if ent, ok := c.entries[rel]; ok {
		c.curBytes -= len(ent.data)
		c.lru.Remove(ent.elem)
		delete(c.entries, rel)
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

	mu        sync.Mutex
	conn      net.Conn
	writeMu   sync.Mutex
	pending   map[uint32]chan []byte
	nextReqID atomic.Uint32
	closed    bool
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
