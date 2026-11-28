//go:build linux

package main

import (
	"net"
	"unsafe"

	"golang.org/x/sys/unix"
)

const pktInfoSize = int(unsafe.Sizeof(unix.Inet4Pktinfo{}))

func enableUDPPktInfo(conn *net.UDPConn) error {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var sockErr error
	if err := rawConn.Control(func(fd uintptr) {
		sockErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_PKTINFO, 1)
	}); err != nil {
		return err
	}
	return sockErr
}

// replyPktInfoOOB preserves the queried destination IP as Spec_dst while
// resetting Ifindex so Linux sends replies with the expected source IP even
// when queried from custom Docker bridge networks on 10.88.x.x.
func replyPktInfoOOB(oob []byte) []byte {
	if len(oob) == 0 {
		return nil
	}
	msgs, err := unix.ParseSocketControlMessage(oob)
	if err != nil {
		return nil
	}
	for _, msg := range msgs {
		if msg.Header.Level != unix.IPPROTO_IP || msg.Header.Type != unix.IP_PKTINFO || len(msg.Data) < pktInfoSize {
			continue
		}
		inInfo := (*unix.Inet4Pktinfo)(unsafe.Pointer(&msg.Data[0]))
		srcIP := inInfo.Spec_dst
		if srcIP == ([4]byte{}) {
			srcIP = inInfo.Addr
		}
		if srcIP == ([4]byte{}) {
			return nil
		}
		return buildPktInfoOOB(srcIP)
	}
	return nil
}

func buildPktInfoOOB(srcIP [4]byte) []byte {
	buf := make([]byte, unix.CmsgSpace(pktInfoSize))
	hdr := (*unix.Cmsghdr)(unsafe.Pointer(&buf[0]))
	hdr.Level = unix.IPPROTO_IP
	hdr.Type = unix.IP_PKTINFO
	hdr.SetLen(unix.CmsgLen(pktInfoSize))
	outInfo := (*unix.Inet4Pktinfo)(unsafe.Pointer(&buf[unix.CmsgLen(0)]))
	outInfo.Ifindex = 0
	outInfo.Spec_dst = srcIP
	outInfo.Addr = [4]byte{}
	return buf
}
