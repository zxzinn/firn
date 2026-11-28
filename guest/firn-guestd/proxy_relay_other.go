//go:build !linux

package main

import "net"

func enableUDPPktInfo(_ *net.UDPConn) error {
	return nil
}

func replyPktInfoOOB(_ []byte) []byte {
	return nil
}
