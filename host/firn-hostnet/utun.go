package main

import (
	"context"
	"encoding/binary"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type utunBridgeServer struct {
	ln     net.Listener
	engine *NetEngine

	mu     sync.Mutex
	client net.Conn
}

func startUtunBridgeServer(ctx context.Context, sockPath string, engine *NetEngine) (*utunBridgeServer, error) {
	_ = os.MkdirAll(filepath.Dir(sockPath), 0o755)
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return nil, err
	}
	// Allow root utun helper (e.g. `sudo firn route up`) to connect to user daemon socket.
	_ = os.Chmod(sockPath, 0o660)
	srv := &utunBridgeServer{ln: ln, engine: engine}
	go func() {
		<-ctx.Done()
		srv.Close()
		_ = os.Remove(sockPath)
	}()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			srv.handleClient(c)
		}
	}()
	return srv, nil
}

func (s *utunBridgeServer) HasClient() bool {
	s.mu.Lock()
	ok := s.client != nil
	s.mu.Unlock()
	return ok
}

func (s *utunBridgeServer) handleClient(c net.Conn) {
	s.mu.Lock()
	old := s.client
	s.client = c
	s.mu.Unlock()
	if old != nil {
		_ = old.Close()
	}
	defer func() {
		s.mu.Lock()
		if s.client == c {
			s.client = nil
		}
		s.mu.Unlock()
		_ = c.Close()
	}()

	var hdr [4]byte
	buf := make([]byte, 65536)
	for {
		if _, err := io.ReadFull(c, hdr[:]); err != nil {
			return
		}
		n := int(binary.BigEndian.Uint32(hdr[:]))
		if n <= 0 || n > len(buf) {
			return
		}
		if _, err := io.ReadFull(c, buf[:n]); err != nil {
			return
		}
		_ = s.engine.InjectUtunIPPacket(buf[:n])
	}
}

func (s *utunBridgeServer) SendIPPacket(ipPkt []byte) {
	s.mu.Lock()
	c := s.client
	s.mu.Unlock()
	if c == nil || len(ipPkt) == 0 {
		return
	}
	var pkt [4 + 65536]byte
	if len(ipPkt) > 65536 {
		return
	}
	binary.BigEndian.PutUint32(pkt[0:4], uint32(len(ipPkt)))
	copy(pkt[4:], ipPkt)
	_, _ = c.Write(pkt[:4+len(ipPkt)])
}

func (s *utunBridgeServer) Close() {
	s.mu.Lock()
	c := s.client
	s.client = nil
	s.mu.Unlock()
	if c != nil {
		_ = c.Close()
	}
	if s.ln != nil {
		_ = s.ln.Close()
	}
}

func runUtunSubcommand(args []string) error {
	fs := flag.NewFlagSet("utun", flag.ExitOnError)
	sockPath := fs.String("sock", filepath.Join(os.Getenv("HOME"), ".firn/run/utun.sock"), "utun bridge socket path")
	_ = fs.Parse(args)

	fd, ifname, err := openUtunDevice()
	if err != nil {
		return err
	}
	defer func() {
		cleanupUtunRoutes(ifname)
		_ = unix.Close(fd)
	}()
	if err := configureUtunRoutes(ifname); err != nil {
		return err
	}
	log.Printf("[firn-utun] %s active (10.89.1.1 -> 10.87.0.0/24, 10.88.0.0/16)", ifname)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	for ctx.Err() == nil {
		conn, derr := net.DialTimeout("unix", *sockPath, 2*time.Second)
		if derr != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}
		bridgeUtunToSocket(ctx, fd, conn)
		_ = conn.Close()
		time.Sleep(250 * time.Millisecond)
	}
	return nil
}

func bridgeUtunToSocket(ctx context.Context, utunFD int, conn net.Conn) {
	done := make(chan struct{})
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()
	go func() {
		defer close(done)
		var hdr [4]byte
		buf := make([]byte, 4+65536)
		for {
			if _, err := io.ReadFull(conn, hdr[:]); err != nil {
				return
			}
			n := int(binary.BigEndian.Uint32(hdr[:]))
			if n <= 0 || n > 65536 {
				return
			}
			if _, err := io.ReadFull(conn, buf[4:4+n]); err != nil {
				return
			}
			// macOS utun expects 4-byte BSD AF_INET (0x00000002) header.
			binary.BigEndian.PutUint32(buf[0:4], uint32(unix.AF_INET))
			_, _ = unix.Write(utunFD, buf[:4+n])
		}
	}()

	raw := make([]byte, 4+65536)
	out := make([]byte, 4+65536)
	for {
		n, err := unix.Read(utunFD, raw)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			_ = conn.Close()
			break
		}
		if n <= 24 {
			continue
		}
		af := binary.BigEndian.Uint32(raw[0:4])
		if af != uint32(unix.AF_INET) {
			continue
		}
		ipPkt := raw[4:n]
		if (ipPkt[0]>>4) != 4 {
			continue
		}
		if !isIPv4UtunTarget(net.IPv4(ipPkt[16], ipPkt[17], ipPkt[18], ipPkt[19])) {
			continue
		}
		binary.BigEndian.PutUint32(out[0:4], uint32(len(ipPkt)))
		copy(out[4:], ipPkt)
		if _, werr := conn.Write(out[:4+len(ipPkt)]); werr != nil {
			break
		}
	}
	<-done
}
