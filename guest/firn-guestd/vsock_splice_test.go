package main

import (
	"bytes"
	"io"
	"net"
	"testing"
)

func TestTCPSpliceHalfClose(t *testing.T) {
	ln1, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln1.Close()

	ln2, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln2.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		c1, err1 := ln1.Accept()
		if err1 != nil {
			return
		}
		c2, err2 := net.Dial("tcp", ln2.Addr().String())
		if err2 != nil {
			_ = c1.Close()
			return
		}
		spliceHalfClose(c1, c2)
	}()

	srvCh := make(chan net.Conn, 1)
	go func() {
		c, _ := ln2.Accept()
		srvCh <- c
	}()

	cli, err := net.Dial("tcp", ln1.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	srv := <-srvCh
	defer cli.Close()
	defer srv.Close()

	payload := bytes.Repeat([]byte("S"), 1536*1024)
	reply := bytes.Repeat([]byte("R"), 128*1024)

	errCh := make(chan error, 1)
	go func() {
		if _, werr := cli.Write(payload); werr != nil {
			errCh <- werr
			return
		}
		if cw, ok := cli.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
		errCh <- nil
	}()

	gotPayload, err := io.ReadAll(srv)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotPayload, payload) {
		t.Fatalf("forward payload mismatch: got %d want %d", len(gotPayload), len(payload))
	}
	if _, err := srv.Write(reply); err != nil {
		t.Fatal(err)
	}
	if cw, ok := srv.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	}

	gotReply, err := io.ReadAll(cli)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotReply, reply) {
		t.Fatalf("reverse reply mismatch: got %d want %d", len(gotReply), len(reply))
	}
	if werr := <-errCh; werr != nil {
		t.Fatal(werr)
	}
	<-done
}
