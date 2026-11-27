package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"time"
)

func serveDockerBridge(vsockPort uint32, dockerSock string) error {
	ln, err := ListenVsock(vsockPort)
	if err != nil {
		return err
	}
	log.Printf("[firn-guestd] docker vsock bridge listening on vsock:%d -> %s", vsockPort, dockerSock)
	for {
		vc, err := ln.Accept()
		if err != nil {
			return err
		}
		go func(client net.Conn) {
			upstream, err := net.DialTimeout("unix", dockerSock, 5*time.Second)
			if err != nil {
				_ = client.Close()
				return
			}
			spliceHalfClose(client, upstream)
		}(vc)
	}
}

func parseTunnelHeader(r io.Reader) (string, uint16, error) {
	var header [2]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return "", 0, err
	}
	if header[0] != 1 {
		return "", 0, fmt.Errorf("unsupported tunnel version %d", header[0])
	}
	hostLen := int(header[1])
	if hostLen == 0 {
		return "", 0, fmt.Errorf("empty target host")
	}
	hostBytes := make([]byte, hostLen)
	if _, err := io.ReadFull(r, hostBytes); err != nil {
		return "", 0, err
	}
	var port uint16
	if err := binary.Read(r, binary.BigEndian, &port); err != nil {
		return "", 0, err
	}
	if port == 0 {
		return "", 0, fmt.Errorf("invalid target port 0")
	}
	return string(hostBytes), port, nil
}

func serveTunnelBridge(vsockPort uint32) error {
	ln, err := ListenVsock(vsockPort)
	if err != nil {
		return err
	}
	log.Printf("[firn-guestd] tcp tunnel bridge listening on vsock:%d", vsockPort)
	for {
		vc, err := ln.Accept()
		if err != nil {
			return err
		}
		go func(client net.Conn) {
			_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
			host, port, err := parseTunnelHeader(client)
			_ = client.SetReadDeadline(time.Time{})
			if err != nil {
				_ = client.Close()
				return
			}
			upstream, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(int(port))), 5*time.Second)
			if err != nil {
				_, _ = client.Write([]byte{0x01})
				_ = client.Close()
				return
			}
			if tc, ok := upstream.(*net.TCPConn); ok {
				_ = tc.SetNoDelay(true)
				_ = tc.SetReadBuffer(8 << 20)
				_ = tc.SetWriteBuffer(8 << 20)
			}
			if _, err := client.Write([]byte{0x00}); err != nil {
				_ = upstream.Close()
				_ = client.Close()
				return
			}
			spliceHalfClose(client, upstream)
		}(vc)
	}
}
