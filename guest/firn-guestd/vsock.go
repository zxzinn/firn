package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	afVsock        = 40
	vmaddrCIDAny   = 0xFFFFFFFF
	vmaddrCIDHost  = 2
	vsockSockLen   = 16
)

type sockaddrVM struct {
	Family    uint16
	Reserved1 uint16
	Port      uint32
	CID       uint32
	Flags     uint8
	Zero      [3]byte
}

func init() {
	if unsafe.Sizeof(sockaddrVM{}) != vsockSockLen {
		panic("sockaddrVM size mismatch")
	}
}

type vsockAddr struct {
	cid  uint32
	port uint32
}

func (a vsockAddr) Network() string { return "vsock" }
func (a vsockAddr) String() string  { return fmt.Sprintf("vsock:%d:%d", a.cid, a.port) }

type vsockConn struct {
	fd     int
	file   *os.File
	local  vsockAddr
	remote vsockAddr
	once   sync.Once
}

func tuneVsockSocketBuffers(fd int) {
	const bufBytes = 1 << 20
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, bufBytes)
	_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, bufBytes)
}

func newVsockConn(fd int, local, remote vsockAddr) (*vsockConn, error) {
	syscall.CloseOnExec(fd)
	tuneVsockSocketBuffers(fd)
	if err := syscall.SetNonblock(fd, true); err != nil {
		_ = syscall.Close(fd)
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "vsock")
	if f == nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("os.NewFile failed for fd %d", fd)
	}
	return &vsockConn{
		fd:     fd,
		file:   f,
		local:  local,
		remote: remote,
	}, nil
}

func (c *vsockConn) Read(b []byte) (int, error)  { return c.file.Read(b) }
func (c *vsockConn) Write(b []byte) (int, error) { return c.file.Write(b) }
func (c *vsockConn) CloseWrite() error           { return syscall.Shutdown(c.fd, syscall.SHUT_WR) }
func (c *vsockConn) LocalAddr() net.Addr         { return c.local }
func (c *vsockConn) RemoteAddr() net.Addr        { return c.remote }

func (c *vsockConn) SetDeadline(t time.Time) error      { return c.file.SetDeadline(t) }
func (c *vsockConn) SetReadDeadline(t time.Time) error  { return c.file.SetReadDeadline(t) }
func (c *vsockConn) SetWriteDeadline(t time.Time) error { return c.file.SetWriteDeadline(t) }

func (c *vsockConn) Close() error {
	var err error
	c.once.Do(func() {
		_ = syscall.Shutdown(c.fd, syscall.SHUT_RDWR)
		err = c.file.Close()
	})
	return err
}

type vsockListener struct {
	fd    int
	local vsockAddr
	once  sync.Once
}

func ListenVsock(port uint32) (net.Listener, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("vsock socket: %w", err)
	}
	syscall.CloseOnExec(fd)
	sa := sockaddrVM{
		Family: afVsock,
		Port:   port,
		CID:    vmaddrCIDAny,
	}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa)), vsockSockLen)
	if errno != 0 {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("vsock bind(%d): %w", port, errno)
	}
	if err := syscall.Listen(fd, 128); err != nil {
		_ = syscall.Close(fd)
		return nil, fmt.Errorf("vsock listen(%d): %w", port, err)
	}
	return &vsockListener{
		fd:    fd,
		local: vsockAddr{cid: vmaddrCIDAny, port: port},
	}, nil
}

func (l *vsockListener) Accept() (net.Conn, error) {
	for {
		var peer sockaddrVM
		peerLen := uint32(vsockSockLen)
		cfd, _, errno := syscall.Syscall(
			syscall.SYS_ACCEPT,
			uintptr(l.fd),
			uintptr(unsafe.Pointer(&peer)),
			uintptr(unsafe.Pointer(&peerLen)),
		)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			return nil, errno
		}
		return newVsockConn(
			int(cfd),
			l.local,
			vsockAddr{cid: peer.CID, port: peer.Port},
		)
	}
}

func (l *vsockListener) Close() error {
	var err error
	l.once.Do(func() {
		_ = syscall.Shutdown(l.fd, syscall.SHUT_RDWR)
		err = syscall.Close(l.fd)
	})
	return err
}

func (l *vsockListener) Addr() net.Addr { return l.local }

func DialVsockHost(port uint32) (net.Conn, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM, 0)
	if err != nil {
		return nil, fmt.Errorf("vsock dial socket: %w", err)
	}
	sa := sockaddrVM{
		Family: afVsock,
		Port:   port,
		CID:    vmaddrCIDHost,
	}
	for {
		_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&sa)), vsockSockLen)
		if errno == syscall.EINTR {
			continue
		}
		if errno != 0 {
			_ = syscall.Close(fd)
			return nil, fmt.Errorf("vsock connect(host:%d): %w", port, errno)
		}
		break
	}
	return newVsockConn(fd, vsockAddr{cid: vmaddrCIDAny, port: 0}, vsockAddr{cid: vmaddrCIDHost, port: port})
}

var copyBufPool = sync.Pool{
	New: func() any {
		buf := make([]byte, 256*1024)
		return &buf
	},
}

func spliceHalfClose(a, b io.ReadWriteCloser) {
	var wg sync.WaitGroup
	wg.Add(2)
	copyDir := func(dst io.WriteCloser, src io.ReadCloser) {
		defer wg.Done()
		bufPtr := copyBufPool.Get().(*[]byte)
		_, _ = io.CopyBuffer(dst, src, *bufPtr)
		copyBufPool.Put(bufPtr)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	go copyDir(a, b)
	go copyDir(b, a)
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
}
