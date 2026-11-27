package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"time"
)

const (
	netstackTunName   = "firn0"
	netstackGuestCIDR = "10.89.0.2/24"
	netstackHostIP    = "10.89.0.1"
	netstackMTU       = 1500
	vsockNetTCPPort   = 2380
	vsockNetUDPPort   = 2381
)

func mapGuestDestHost(destIP string) string {
	if destIP == netstackHostIP {
		return "127.0.0.1"
	}
	return destIP
}

func writeTunnelDialHeader(w io.Writer, proto byte, host string, port uint16) error {
	if len(host) == 0 || len(host) > 255 {
		return fmt.Errorf("invalid tunnel destination host %q", host)
	}
	buf := make([]byte, 2+len(host)+2)
	buf[0] = proto
	buf[1] = byte(len(host))
	copy(buf[2:], host)
	binary.BigEndian.PutUint16(buf[2+len(host):], port)
	_, err := w.Write(buf)
	return err
}

func dialHostTunnel(vsockPort uint32, proto byte, destIP string, destPort uint16) (net.Conn, error) {
	conn, err := DialVsockHost(vsockPort)
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if err := writeTunnelDialHeader(conn, proto, mapGuestDestHost(destIP), destPort); err != nil {
		_ = conn.Close()
		return nil, err
	}
	var ack [1]byte
	if _, err := io.ReadFull(conn, ack[:]); err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	if ack[0] != 0x00 {
		_ = conn.Close()
		return nil, fmt.Errorf("host tunnel refused %s:%d (code %d)", destIP, destPort, ack[0])
	}
	return conn, nil
}
