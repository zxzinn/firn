package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
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

	fsPrefetchMaxFiles     = 1024
	fsPrefetchMaxFile      = 64 * 1024
	fsPrefetchMaxTotal     = 8 * 1024 * 1024
	fsDeepPrefetchMaxDirs  = 64
	fsDeepPrefetchMaxFiles = 2048
	fsDeepPrefetchMaxTotal = 8 * 1024 * 1024

	// Portable Linux errno numbers for Darwin -> Linux FUSE wire responses.
	lnxEPERM        uint32 = 1
	lnxENOENT       uint32 = 2
	lnxEIO          uint32 = 5
	lnxEACCES       uint32 = 13
	lnxEEXIST       uint32 = 17
	lnxENOTDIR      uint32 = 20
	lnxEISDIR       uint32 = 21
	lnxEINVAL       uint32 = 22
	lnxENOSPC       uint32 = 28
	lnxEROFS        uint32 = 30
	lnxENAMETOOLONG uint32 = 36
	lnxENOTEMPTY    uint32 = 39
	lnxELOOP        uint32 = 40
	lnxEOPNOTSUPP   uint32 = 95

	// Linux POSIX file type bits for Mode.
	lnxSIFMT   uint32 = 0o170000
	lnxSIFSOCK uint32 = 0o140000
	lnxSIFLNK  uint32 = 0o120000
	lnxSIFREG  uint32 = 0o100000
	lnxSIFBLK  uint32 = 0o060000
	lnxSIFDIR  uint32 = 0o040000
	lnxSIFCHR  uint32 = 0o020000
	lnxSIFIFO  uint32 = 0o010000
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

type FirnFSServer struct {
	root string

	mu      sync.Mutex
	clients map[*fsClientConn]bool
}

type fsClientConn struct {
	conn          net.Conn
	writeMu       sync.Mutex
	prefetchSlots atomic.Int32
}

func NewFirnFSServer(root string) (*FirnFSServer, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	return &FirnFSServer{
		root:    abs,
		clients: make(map[*fsClientConn]bool),
	}, nil
}

func (s *FirnFSServer) ClientCount() int {
	s.mu.Lock()
	n := len(s.clients)
	s.mu.Unlock()
	return n
}

func (s *FirnFSServer) ServeListener(ctx context.Context, ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go s.serveConn(ctx, c)
	}
}

func (s *FirnFSServer) ServeUnix(ctx context.Context, sockPath string) error {
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return err
	}
	go s.ServeListener(ctx, ln)
	go func() {
		<-ctx.Done()
		_ = ln.Close()
		_ = os.Remove(sockPath)
	}()
	return nil
}

func (s *FirnFSServer) serveConn(ctx context.Context, conn net.Conn) {
	cc := &fsClientConn{conn: conn}
	s.mu.Lock()
	s.clients[cc] = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, cc)
		s.mu.Unlock()
		_ = conn.Close()
	}()

	var hdr [9]byte
	for {
		if ctx.Err() != nil {
			return
		}
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
		// Dispatch concurrently so slow disk I/O doesn't stall metadata lookups.
		go func(id uint32, opc byte, req []byte) {
			if opc == fsOpReaddirPref {
				off := 0
				rel, ok := readShortStr(req, &off)
				if !ok {
					_ = cc.writeFrame(id, opc, encodeErrno(lnxEINVAL))
					return
				}
				resp, subdirs := s.handleReaddirPrefetchWithSubdirs(rel)
				if werr := cc.writeFrame(id, opc, resp); werr != nil {
					return
				}
				cleanRel := strings.TrimPrefix(filepath.ToSlash(filepath.Clean("/"+rel)), "/")
				if cleanRel == "." {
					cleanRel = ""
				}
				if cleanRel != "" && len(subdirs) > 0 {
					if cc.prefetchSlots.Add(1) <= 2 {
						go func() {
							defer cc.prefetchSlots.Add(-1)
							s.streamSubdirPrefetch(ctx, cc, cleanRel, subdirs)
						}()
					} else {
						cc.prefetchSlots.Add(-1)
					}
				}
				return
			}
			resp := s.handleOp(opc, req)
			_ = cc.writeFrame(id, opc, resp)
		}(reqID, op, payload)
	}
}

func (cc *fsClientConn) writeFrame(reqID uint32, op byte, payload []byte) error {
	buf := make([]byte, 9+len(payload))
	binary.BigEndian.PutUint32(buf[0:4], reqID)
	buf[4] = op
	binary.BigEndian.PutUint32(buf[5:9], uint32(len(payload)))
	if len(payload) > 0 {
		copy(buf[9:], payload)
	}
	cc.writeMu.Lock()
	defer cc.writeMu.Unlock()
	_, err := cc.conn.Write(buf)
	return err
}

func (s *FirnFSServer) BroadcastInvalidations(relPaths []string) {
	if len(relPaths) == 0 {
		return
	}
	var buf bytes.Buffer
	var tmp2 [2]byte
	cleaned := make([]string, 0, len(relPaths))
	for _, p := range relPaths {
		p = strings.TrimPrefix(filepath.ToSlash(filepath.Clean("/"+p)), "/")
		cleaned = append(cleaned, p)
	}
	if len(cleaned) > 4096 {
		cleaned = cleaned[:4096]
	}
	binary.BigEndian.PutUint16(tmp2[:], uint16(len(cleaned)))
	buf.Write(tmp2[:])
	for _, p := range cleaned {
		writeShortStr(&buf, p)
	}
	payload := buf.Bytes()

	s.mu.Lock()
	conns := make([]*fsClientConn, 0, len(s.clients))
	for c := range s.clients {
		conns = append(conns, c)
	}
	s.mu.Unlock()

	for _, cc := range conns {
		_ = cc.writeFrame(0, fsOpPushInvalidate, payload)
	}
}

func (s *FirnFSServer) resolveRel(rel string) (string, error) {
	if strings.ContainsRune(rel, 0) {
		return "", syscall.EINVAL
	}
	clean := filepath.Clean("/" + strings.TrimPrefix(rel, "/"))
	full := filepath.Join(s.root, strings.TrimPrefix(clean, "/"))
	if full != s.root && !strings.HasPrefix(full, s.root+string(filepath.Separator)) {
		return "", syscall.EACCES
	}
	return full, nil
}

func toLinuxErrno(err error) uint32 {
	if err == nil {
		return 0
	}
	var se syscall.Errno
	if errors.As(err, &se) {
		switch se {
		case syscall.EPERM:
			return lnxEPERM
		case syscall.ENOENT:
			return lnxENOENT
		case syscall.EIO:
			return lnxEIO
		case syscall.EACCES:
			return lnxEACCES
		case syscall.EEXIST:
			return lnxEEXIST
		case syscall.ENOTDIR:
			return lnxENOTDIR
		case syscall.EISDIR:
			return lnxEISDIR
		case syscall.EINVAL:
			return lnxEINVAL
		case syscall.ENOSPC:
			return lnxENOSPC
		case syscall.EROFS:
			return lnxEROFS
		case syscall.ENAMETOOLONG:
			return lnxENAMETOOLONG
		case syscall.ENOTEMPTY:
			return lnxENOTEMPTY
		case syscall.ELOOP:
			return lnxELOOP
		case syscall.EOPNOTSUPP:
			return lnxEOPNOTSUPP
		default:
			return uint32(se)
		}
	}
	if os.IsNotExist(err) {
		return lnxENOENT
	}
	if os.IsPermission(err) {
		return lnxEACCES
	}
	if os.IsExist(err) {
		return lnxEEXIST
	}
	return lnxEIO
}

func lstatToAttr(path string) (fsAttrWire, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return fsAttrWire{}, err
	}
	return statToAttr(&st), nil
}

func statToAttr(st *syscall.Stat_t) fsAttrWire {
	perm := uint32(st.Mode) & 0o7777
	var lnxType uint32
	switch uint32(st.Mode) & syscall.S_IFMT {
	case syscall.S_IFDIR:
		lnxType = lnxSIFDIR
	case syscall.S_IFLNK:
		lnxType = lnxSIFLNK
	case syscall.S_IFIFO:
		lnxType = lnxSIFIFO
	case syscall.S_IFSOCK:
		lnxType = lnxSIFSOCK
	case syscall.S_IFBLK:
		lnxType = lnxSIFBLK
	case syscall.S_IFCHR:
		lnxType = lnxSIFCHR
	default:
		lnxType = lnxSIFREG
	}
	return fsAttrWire{
		Ino:     st.Ino,
		Size:    uint64(st.Size),
		Blocks:  uint64(st.Blocks),
		AtimeNs: statAtimeNs(st),
		MtimeNs: statMtimeNs(st),
		CtimeNs: statCtimeNs(st),
		Mode:    lnxType | perm,
		Nlink:   uint32(st.Nlink),
		UID:     st.Uid,
		GID:     st.Gid,
	}
}

func encodeErrno(errno uint32) []byte {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], errno)
	return b[:]
}

func writeAttr(buf *bytes.Buffer, a fsAttrWire) {
	var raw [64]byte
	binary.BigEndian.PutUint64(raw[0:8], a.Ino)
	binary.BigEndian.PutUint64(raw[8:16], a.Size)
	binary.BigEndian.PutUint64(raw[16:24], a.Blocks)
	binary.BigEndian.PutUint64(raw[24:32], uint64(a.AtimeNs))
	binary.BigEndian.PutUint64(raw[32:40], uint64(a.MtimeNs))
	binary.BigEndian.PutUint64(raw[40:48], uint64(a.CtimeNs))
	binary.BigEndian.PutUint32(raw[48:52], a.Mode)
	binary.BigEndian.PutUint32(raw[52:56], a.Nlink)
	binary.BigEndian.PutUint32(raw[56:60], a.UID)
	binary.BigEndian.PutUint32(raw[60:64], a.GID)
	buf.Write(raw[:])
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

func (s *FirnFSServer) handleOp(op byte, req []byte) []byte {
	switch op {
	case fsOpGetattr, fsOpLookup:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		attr, err := lstatToAttr(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpReaddirPref:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok {
			return encodeErrno(lnxEINVAL)
		}
		return s.handleReaddirPrefetch(rel)

	case fsOpRead:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok || off+12 > len(req) {
			return encodeErrno(lnxEINVAL)
		}
		offset := int64(binary.BigEndian.Uint64(req[off : off+8]))
		size := int(binary.BigEndian.Uint32(req[off+8 : off+12]))
		if size < 0 || size > 4*1024*1024 {
			size = 4 * 1024 * 1024
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		f, err := os.Open(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		defer f.Close()
		buf := make([]byte, size)
		n, rerr := f.ReadAt(buf, offset)
		if rerr != nil && !errors.Is(rerr, io.EOF) {
			return encodeErrno(toLinuxErrno(rerr))
		}
		var out bytes.Buffer
		out.Grow(8 + n)
		out.Write(encodeErrno(0))
		var lb [4]byte
		binary.BigEndian.PutUint32(lb[:], uint32(n))
		out.Write(lb[:])
		out.Write(buf[:n])
		return out.Bytes()

	case fsOpWrite:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok || off+16 > len(req) {
			return encodeErrno(lnxEINVAL)
		}
		offset := int64(binary.BigEndian.Uint64(req[off : off+8]))
		_ = binary.BigEndian.Uint32(req[off+8 : off+12])
		dlen := int(binary.BigEndian.Uint32(req[off+12 : off+16]))
		off += 16
		if dlen < 0 || off+dlen > len(req) {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		f, err := os.OpenFile(full, os.O_WRONLY, 0)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		n, werr := f.WriteAt(req[off:off+dlen], offset)
		_ = f.Close()
		if werr != nil {
			return encodeErrno(toLinuxErrno(werr))
		}
		attr, err := lstatToAttr(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		var wb [4]byte
		binary.BigEndian.PutUint32(wb[:], uint32(n))
		out.Write(wb[:])
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpCreate:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok || off+8 > len(req) {
			return encodeErrno(lnxEINVAL)
		}
		mode := binary.BigEndian.Uint32(req[off : off+4])
		flags := int(binary.BigEndian.Uint32(req[off+4 : off+8]))
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		oflags := os.O_CREATE | os.O_RDWR
		if (flags & int(syscall.O_EXCL)) != 0 {
			oflags |= os.O_EXCL
		}
		if (flags & int(syscall.O_TRUNC)) != 0 {
			oflags |= os.O_TRUNC
		}
		perm := os.FileMode(mode & 0o7777)
		if perm == 0 {
			perm = 0o644
		}
		f, err := os.OpenFile(full, oflags, perm)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		_ = f.Close()
		attr, err := lstatToAttr(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpMkdir:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok || off+4 > len(req) {
			return encodeErrno(lnxEINVAL)
		}
		mode := binary.BigEndian.Uint32(req[off : off+4])
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		perm := os.FileMode(mode & 0o7777)
		if perm == 0 {
			perm = 0o755
		}
		if err := os.Mkdir(full, perm); err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		attr, err := lstatToAttr(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpUnlink:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		return encodeErrno(toLinuxErrno(syscall.Unlink(full)))

	case fsOpRmdir:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		return encodeErrno(toLinuxErrno(syscall.Rmdir(full)))

	case fsOpRename:
		off := 0
		oldRel, ok1 := readShortStr(req, &off)
		newRel, ok2 := readShortStr(req, &off)
		if !ok1 || !ok2 {
			return encodeErrno(lnxEINVAL)
		}
		oldFull, err := s.resolveRel(oldRel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		newFull, err := s.resolveRel(newRel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		return encodeErrno(toLinuxErrno(os.Rename(oldFull, newFull)))

	case fsOpSetattr:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok || off+40 > len(req) {
			return encodeErrno(lnxEINVAL)
		}
		valid := binary.BigEndian.Uint32(req[off : off+4])
		mode := binary.BigEndian.Uint32(req[off+4 : off+8])
		_ = binary.BigEndian.Uint32(req[off+8 : off+12])
		_ = binary.BigEndian.Uint32(req[off+12 : off+16])
		size := int64(binary.BigEndian.Uint64(req[off+16 : off+24]))
		atimeNs := int64(binary.BigEndian.Uint64(req[off+24 : off+32]))
		mtimeNs := int64(binary.BigEndian.Uint64(req[off+32 : off+40]))

		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		if (valid & (1 << 0)) != 0 { // mode
			if err := os.Chmod(full, os.FileMode(mode&0o7777)); err != nil {
				return encodeErrno(toLinuxErrno(err))
			}
		}
		if (valid & (1 << 3)) != 0 { // size
			if err := os.Truncate(full, size); err != nil {
				return encodeErrno(toLinuxErrno(err))
			}
		}
		if (valid & ((1 << 4) | (1 << 5))) != 0 { // atime / mtime
			at, mt, err := statTimes(full)
			if err != nil {
				return encodeErrno(toLinuxErrno(err))
			}
			if (valid & (1 << 4)) != 0 {
				at = syscall.NsecToTimespec(atimeNs)
			}
			if (valid & (1 << 5)) != 0 {
				mt = syscall.NsecToTimespec(mtimeNs)
			}
			if err := syscall.UtimesNano(full, []syscall.Timespec{at, mt}); err != nil {
				return encodeErrno(toLinuxErrno(err))
			}
		}
		attr, err := lstatToAttr(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpFsync:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		f, err := os.OpenFile(full, os.O_RDONLY, 0)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		serr := f.Sync()
		_ = f.Close()
		return encodeErrno(toLinuxErrno(serr))

	case fsOpSymlink:
		off := 0
		rel, ok1 := readShortStr(req, &off)
		target, ok2 := readShortStr(req, &off)
		if !ok1 || !ok2 {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		if err := os.Symlink(target, full); err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		attr, err := lstatToAttr(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpReadlink:
		off := 0
		rel, ok := readShortStr(req, &off)
		if !ok {
			return encodeErrno(lnxEINVAL)
		}
		full, err := s.resolveRel(rel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		target, err := os.Readlink(full)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeShortStr(&out, target)
		return out.Bytes()

	case fsOpLink:
		off := 0
		targetRel, ok1 := readShortStr(req, &off)
		newRel, ok2 := readShortStr(req, &off)
		if !ok1 || !ok2 {
			return encodeErrno(lnxEINVAL)
		}
		targetFull, err := s.resolveRel(targetRel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		newFull, err := s.resolveRel(newRel)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		if err := os.Link(targetFull, newFull); err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		attr, err := lstatToAttr(newFull)
		if err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var out bytes.Buffer
		out.Write(encodeErrno(0))
		writeAttr(&out, attr)
		return out.Bytes()

	case fsOpStatfs:
		var st syscall.Statfs_t
		if err := syscall.Statfs(s.root, &st); err != nil {
			return encodeErrno(toLinuxErrno(err))
		}
		var raw [52]byte
		binary.BigEndian.PutUint32(raw[0:4], 0)
		binary.BigEndian.PutUint64(raw[4:12], st.Blocks)
		binary.BigEndian.PutUint64(raw[12:20], st.Bfree)
		binary.BigEndian.PutUint64(raw[20:28], st.Bavail)
		binary.BigEndian.PutUint64(raw[28:36], st.Files)
		binary.BigEndian.PutUint64(raw[36:44], st.Ffree)
		binary.BigEndian.PutUint32(raw[44:48], uint32(st.Bsize))
		binary.BigEndian.PutUint32(raw[48:52], uint32(st.Bsize))
		return raw[:]

	default:
		return encodeErrno(lnxEOPNOTSUPP)
	}
}

type prefetchEntry struct {
	name    string
	attr    fsAttrWire
	hasData bool
	data    []byte
}

type prefetchBudget struct {
	mu       sync.Mutex
	files    int
	bytes    int
	maxFiles int
	maxBytes int
}

func (b *prefetchBudget) reserve(size int) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.files >= b.maxFiles || b.bytes+size > b.maxBytes {
		return false
	}
	b.files++
	b.bytes += size
	return true
}

func shouldSkipPrefetchSubdir(name string) bool {
	switch name {
	case ".git", "node_modules", ".Trash", "Library", ".cache", ".firn", ".build", "target", "__pycache__", ".venv":
		return true
	default:
		return false
	}
}

func (s *FirnFSServer) collectDirPrefetchEntries(full string, budget *prefetchBudget) ([]prefetchEntry, []string, error) {
	entries, err := os.ReadDir(full)
	if err != nil {
		return nil, nil, err
	}

	results := make([]prefetchEntry, len(entries))
	valid := make([]bool, len(entries))
	workers := min(16, max(1, runtime.NumCPU()))
	if len(entries) < workers {
		workers = max(1, len(entries))
	}

	idxCh := make(chan int, len(entries))
	for i := range entries {
		idxCh <- i
	}
	close(idxCh)

	var wg sync.WaitGroup
	var subdirsMu sync.Mutex
	var subdirs []string

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range idxCh {
				name := entries[idx].Name()
				ep := filepath.Join(full, name)
				attr, aerr := lstatToAttr(ep)
				if aerr != nil {
					continue
				}
				pe := prefetchEntry{name: name, attr: attr}
				ftype := attr.Mode & lnxSIFMT
				if ftype == lnxSIFDIR {
					if !shouldSkipPrefetchSubdir(name) {
						subdirsMu.Lock()
						subdirs = append(subdirs, name)
						subdirsMu.Unlock()
					}
				} else if ftype == lnxSIFREG && attr.Size <= fsPrefetchMaxFile {
					if budget.reserve(int(attr.Size)) {
						if b, rerr := os.ReadFile(ep); rerr == nil {
							pe.hasData = true
							pe.data = b
							pe.attr.Size = uint64(len(b))
						}
					}
				}
				results[idx] = pe
				valid[idx] = true
			}
		}()
	}
	wg.Wait()

	out := make([]prefetchEntry, 0, len(entries))
	for i, pe := range results {
		if valid[i] {
			out = append(out, pe)
		}
	}
	return out, subdirs, nil
}

func encodePrefetchEntries(out *bytes.Buffer, entries []prefetchEntry) {
	var cntBuf [4]byte
	binary.BigEndian.PutUint32(cntBuf[:], uint32(len(entries)))
	out.Write(cntBuf[:])
	for _, pe := range entries {
		writeShortStr(out, pe.name)
		writeAttr(out, pe.attr)
		if pe.hasData {
			out.WriteByte(1)
			var dl [4]byte
			binary.BigEndian.PutUint32(dl[:], uint32(len(pe.data)))
			out.Write(dl[:])
			out.Write(pe.data)
		} else {
			out.WriteByte(0)
		}
	}
}

func (s *FirnFSServer) handleReaddirPrefetch(rel string) []byte {
	resp, _ := s.handleReaddirPrefetchWithSubdirs(rel)
	return resp
}

func (s *FirnFSServer) handleReaddirPrefetchWithSubdirs(rel string) ([]byte, []string) {
	full, err := s.resolveRel(rel)
	if err != nil {
		return encodeErrno(toLinuxErrno(err)), nil
	}
	budget := prefetchBudget{maxFiles: fsPrefetchMaxFiles, maxBytes: fsPrefetchMaxTotal}
	entries, subdirs, err := s.collectDirPrefetchEntries(full, &budget)
	if err != nil {
		return encodeErrno(toLinuxErrno(err)), nil
	}
	var out bytes.Buffer
	out.Write(encodeErrno(0))
	encodePrefetchEntries(&out, entries)
	return out.Bytes(), subdirs
}

func (s *FirnFSServer) streamSubdirPrefetch(ctx context.Context, cc *fsClientConn, parentRel string, subdirs []string) {
	if len(subdirs) > fsDeepPrefetchMaxDirs {
		subdirs = subdirs[:fsDeepPrefetchMaxDirs]
	}
	budget := prefetchBudget{maxFiles: fsDeepPrefetchMaxFiles, maxBytes: fsDeepPrefetchMaxTotal}
	workers := min(16, max(1, len(subdirs)))
	subCh := make(chan string, len(subdirs))
	for _, name := range subdirs {
		subCh <- name
	}
	close(subCh)

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for subName := range subCh {
				if ctx.Err() != nil {
					return
				}
				subRel := parentRel + "/" + subName
				subFull, err := s.resolveRel(subRel)
				if err != nil {
					continue
				}
				entries, _, err := s.collectDirPrefetchEntries(subFull, &budget)
				if err != nil {
					continue
				}
				var payload bytes.Buffer
				writeShortStr(&payload, subRel)
				encodePrefetchEntries(&payload, entries)
				if cc.writeFrame(0, fsOpPushPrefetch, payload.Bytes()) != nil {
					return
				}
			}
		}()
	}
	wg.Wait()
}

func statTimes(path string) (syscall.Timespec, syscall.Timespec, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return syscall.Timespec{}, syscall.Timespec{}, err
	}
	return syscall.NsecToTimespec(statAtimeNs(&st)), syscall.NsecToTimespec(statMtimeNs(&st)), nil
}

func fmtRel(p string) string {
	return fmt.Sprintf("%s", p)
}
