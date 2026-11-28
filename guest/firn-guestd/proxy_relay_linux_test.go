//go:build linux

package main

import (
	"testing"
	"unsafe"

	"golang.org/x/sys/unix"
)

func TestReplyPktInfoOOBPreservesSpecDst(t *testing.T) {
	inBuf := make([]byte, unix.CmsgSpace(pktInfoSize))
	inHdr := (*unix.Cmsghdr)(unsafe.Pointer(&inBuf[0]))
	inHdr.Level = unix.IPPROTO_IP
	inHdr.Type = unix.IP_PKTINFO
	inHdr.SetLen(unix.CmsgLen(pktInfoSize))
	inInfo := (*unix.Inet4Pktinfo)(unsafe.Pointer(&inBuf[unix.CmsgLen(0)]))
	inInfo.Ifindex = 7
	inInfo.Spec_dst = [4]byte{10, 87, 0, 1}
	inInfo.Addr = [4]byte{10, 88, 0, 8}

	outBuf := replyPktInfoOOB(inBuf)
	if len(outBuf) == 0 {
		t.Fatalf("expected non-empty reply OOB control message")
	}
	msgs, err := unix.ParseSocketControlMessage(outBuf)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("ParseSocketControlMessage failed: len=%d err=%v", len(msgs), err)
	}
	outInfo := (*unix.Inet4Pktinfo)(unsafe.Pointer(&msgs[0].Data[0]))
	if outInfo.Ifindex != 0 {
		t.Fatalf("expected Ifindex=0 for routing flexibility, got %d", outInfo.Ifindex)
	}
	if outInfo.Spec_dst != [4]byte{10, 87, 0, 1} {
		t.Fatalf("expected Spec_dst=10.87.0.1, got %v", outInfo.Spec_dst)
	}
}
