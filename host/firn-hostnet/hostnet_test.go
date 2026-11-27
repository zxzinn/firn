package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/ethernet"
	"gvisor.dev/gvisor/pkg/tcpip/network/arp"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

func TestFirnFSPathConfinementAndPrefetch(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "proj")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "hello.txt"), []byte("world-123"), 0o644); err != nil {
		t.Fatal(err)
	}
	srv, err := NewFirnFSServer(root)
	if err != nil {
		t.Fatal(err)
	}

	// Path traversal attempt stays confined or denied
	resolved, err := srv.resolveRel("../../etc/passwd")
	if err == nil && !strings.HasPrefix(resolved, srv.root) {
		t.Fatalf("path traversal escaped root: %s", resolved)
	}

	// Lookup hello.txt
	var req bytes.Buffer
	writeShortStr(&req, "proj/hello.txt")
	resp := srv.handleOp(fsOpLookup, req.Bytes())
	if len(resp) < 68 || binary.BigEndian.Uint32(resp[0:4]) != 0 {
		t.Fatalf("unexpected lookup response len=%d errno=%d", len(resp), binary.BigEndian.Uint32(resp[0:4]))
	}
	if gotSize := binary.BigEndian.Uint64(resp[12:20]); gotSize != 9 {
		t.Fatalf("expected size 9, got %d", gotSize)
	}

	// Readdir prefetch returns inline bytes for hello.txt
	var rdReq bytes.Buffer
	writeShortStr(&rdReq, "proj")
	rdResp := srv.handleOp(fsOpReaddirPref, rdReq.Bytes())
	if len(rdResp) < 10 || binary.BigEndian.Uint32(rdResp[0:4]) != 0 {
		t.Fatalf("readdir prefetch failed: len=%d", len(rdResp))
	}
	if cnt := binary.BigEndian.Uint32(rdResp[4:8]); cnt != 1 {
		t.Fatalf("expected 1 entry, got %d", cnt)
	}
	if !bytes.Contains(rdResp, []byte("world-123")) {
		t.Fatalf("expected inline file payload in readdir prefetch response")
	}

	// Create + Write + Read + Unlink cycle
	var cReq bytes.Buffer
	writeShortStr(&cReq, "proj/created.txt")
	_ = binary.Write(&cReq, binary.BigEndian, uint32(0o644))
	_ = binary.Write(&cReq, binary.BigEndian, uint32(0))
	if cResp := srv.handleOp(fsOpCreate, cReq.Bytes()); binary.BigEndian.Uint32(cResp[0:4]) != 0 {
		t.Fatalf("create failed: %d", binary.BigEndian.Uint32(cResp[0:4]))
	}
	var wReq bytes.Buffer
	writeShortStr(&wReq, "proj/created.txt")
	_ = binary.Write(&wReq, binary.BigEndian, int64(0))
	_ = binary.Write(&wReq, binary.BigEndian, uint32(0))
	_ = binary.Write(&wReq, binary.BigEndian, uint32(5))
	wReq.WriteString("hello")
	if wResp := srv.handleOp(fsOpWrite, wReq.Bytes()); binary.BigEndian.Uint32(wResp[0:4]) != 0 {
		t.Fatalf("write failed: %d", binary.BigEndian.Uint32(wResp[0:4]))
	}
	gotBytes, err := os.ReadFile(filepath.Join(sub, "created.txt"))
	if err != nil || string(gotBytes) != "hello" {
		t.Fatalf("expected 'hello', got %q (%v)", string(gotBytes), err)
	}
	var uReq bytes.Buffer
	writeShortStr(&uReq, "proj/created.txt")
	if uResp := srv.handleOp(fsOpUnlink, uReq.Bytes()); binary.BigEndian.Uint32(uResp[0:4]) != 0 {
		t.Fatalf("unlink failed: %d", binary.BigEndian.Uint32(uResp[0:4]))
	}
}

func TestFirnFSDepth2StreamingPrefetch(t *testing.T) {
	root := t.TempDir()
	work := filepath.Join(root, "work")
	for _, sub := range []string{"d00", "d01", "node_modules"} {
		dir := filepath.Join(work, sub)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "item.txt"), []byte("payload-"+sub), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	srv, err := NewFirnFSServer(root)
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cConn, sConn := net.Pipe()
	defer cConn.Close()
	go srv.serveConn(ctx, sConn)

	var reqPayload bytes.Buffer
	writeShortStr(&reqPayload, "work")
	var reqHdr [9]byte
	binary.BigEndian.PutUint32(reqHdr[0:4], 11)
	reqHdr[4] = fsOpReaddirPref
	binary.BigEndian.PutUint32(reqHdr[5:9], uint32(reqPayload.Len()))
	if _, err := cConn.Write(append(reqHdr[:], reqPayload.Bytes()...)); err != nil {
		t.Fatal(err)
	}

	_ = cConn.SetReadDeadline(time.Now().Add(3 * time.Second))
	gotReply := false
	prefetched := make(map[string]bool)
	for len(prefetched) < 2 || !gotReply {
		var hdr [9]byte
		if _, err := io.ReadFull(cConn, hdr[:]); err != nil {
			t.Fatalf("read frame failed (gotReply=%v prefetched=%v): %v", gotReply, prefetched, err)
		}
		id := binary.BigEndian.Uint32(hdr[0:4])
		op := hdr[4]
		plen := binary.BigEndian.Uint32(hdr[5:9])
		body := make([]byte, plen)
		if plen > 0 {
			if _, err := io.ReadFull(cConn, body); err != nil {
				t.Fatal(err)
			}
		}
		if id == 11 && op == fsOpReaddirPref {
			gotReply = true
			continue
		}
		if id == 0 && op == fsOpPushPrefetch {
			off := 0
			dirRel, ok := readShortStr(body, &off)
			if !ok {
				t.Fatalf("bad push prefetch dirRel")
			}
			if strings.Contains(dirRel, "node_modules") {
				t.Fatalf("expected node_modules to be skipped by Depth-2 prefetch, got %q", dirRel)
			}
			prefetched[dirRel] = true
		}
	}
	if !prefetched["work/d00"] || !prefetched["work/d01"] {
		t.Fatalf("expected Depth-2 push prefetch for work/d00 and work/d01, got %v", prefetched)
	}
}

func TestDynamicLeafCertAndTLSHandshake(t *testing.T) {
	dir := t.TempDir()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Firn Test CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	caCertPath := filepath.Join(dir, "ca.crt")
	caKeyPath := filepath.Join(dir, "ca.key")
	_ = os.WriteFile(caCertPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), 0o644)
	kDER, _ := x509.MarshalECPrivateKey(caKey)
	_ = os.WriteFile(caKeyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kDER}), 0o600)

	pm := NewProxyManager(ProxyManagerConfig{
		Domain: "firn.local",
		CACert: caCertPath,
		CAKey:  caKeyPath,
	})
	leaf, err := pm.getLeafCertificate(&tls.ClientHelloInfo{ServerName: "api.myapp.firn.local"})
	if err != nil {
		t.Fatalf("getLeafCertificate failed: %v", err)
	}
	if err := leaf.Leaf.VerifyHostname("api.myapp.firn.local"); err != nil {
		t.Fatalf("leaf SAN did not verify target hostname: %v", err)
	}
	pool := x509.NewCertPool()
	caParsed, _ := x509.ParseCertificate(caDER)
	pool.AddCert(caParsed)
	if _, err := leaf.Leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "api.myapp.firn.local"}); err != nil {
		t.Fatalf("leaf cert failed chain verification against CA: %v", err)
	}
}

func TestSocketpairJumboNetstackConnectivity(t *testing.T) {
	sv, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	tuneDgramSocket(sv[0])
	tuneDgramSocket(sv[1])

	eng, err := NewNetEngine(NetEngineConfig{MTU: 16384})
	if err != nil {
		_ = unix.Close(sv[0])
		_ = unix.Close(sv[1])
		t.Fatal(err)
	}
	defer eng.Close()

	if err := eng.AttachSocketpairFD(sv[0]); err != nil {
		_ = unix.Close(sv[1])
		t.Fatal(err)
	}

	// Verify peer fd can transmit 16,398-byte jumbo Ethernet frame without EMSGSIZE.
	peer := os.NewFile(uintptr(sv[1]), "peer")
	defer peer.Close()
	frame := make([]byte, 14+16384)
	copy(frame[0:6], hostMAC)
	copy(frame[6:12], guestMAC)
	binary.BigEndian.PutUint16(frame[12:14], 0x0800)
	if _, err := peer.Write(frame); err != nil {
		t.Fatalf("jumbo frame write over AF_UNIX SOCK_DGRAM failed: %v", err)
	}
	if eng.Stats().MTU != 16384 || !eng.Stats().VMNetConnected {
		t.Fatalf("unexpected NetEngine stats: %+v", eng.Stats())
	}
	_ = isIPv4UtunTarget(net.IPv4(10, 88, 0, 5))
}

func TestFullStackTCPAndFirnFSRPC(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "sample.bin"), []byte("firn-jumbo-payload"), 0o644); err != nil {
		t.Fatal(err)
	}
	fsSrv, err := NewFirnFSServer(dir)
	if err != nil {
		t.Fatal(err)
	}

	sv, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	tuneDgramSocket(sv[0])
	tuneDgramSocket(sv[1])

	eng, err := NewNetEngine(NetEngineConfig{MTU: 16384, FSServer: fsSrv})
	if err != nil {
		_ = unix.Close(sv[0])
		_ = unix.Close(sv[1])
		t.Fatal(err)
	}
	defer eng.Close()
	if err := eng.AttachSocketpairFD(sv[0]); err != nil {
		_ = unix.Close(sv[1])
		t.Fatal(err)
	}

	// Build peer gVisor stack simulating Linux guest eth0 (10.89.0.2/24, MTU 16384).
	guestStack := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, arp.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	defer guestStack.Close()

	peerEng := &NetEngine{}
	rawPeer := newDgramL2Endpoint(16384, guestMAC, peerEng)
	if err := rawPeer.SetFD(sv[1]); err != nil {
		t.Fatal(err)
	}
	defer rawPeer.Close()

	ethPeer := ethernet.NewWithNetworkMTU(rawPeer)
	if terr := guestStack.CreateNIC(nicID, ethPeer); terr != nil {
		t.Fatalf("guest CreateNIC: %s", terr)
	}
	guestAddr := tcpip.AddrFrom4Slice(netip.MustParseAddr(guestNetIPStr).AsSlice())
	hostAddr := tcpip.AddrFrom4Slice(netip.MustParseAddr(hostNetIPStr).AsSlice())
	if terr := guestStack.AddProtocolAddress(nicID, tcpip.ProtocolAddress{
		Protocol: ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{
			Address:   guestAddr,
			PrefixLen: 24,
		},
	}, stack.AddressProperties{}); terr != nil {
		t.Fatalf("guest AddProtocolAddress: %s", terr)
	}
	guestStack.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: nicID},
	})
	_ = guestStack.AddStaticNeighbor(nicID, ipv4.ProtocolNumber, hostAddr, hostMAC)

	// 1. Verify DialGuestTCP across jumbo 16384 MTU L2 link with 256 KiB payload.
	guestLn, err := gonet.ListenTCP(guestStack, tcpip.FullAddress{NIC: nicID, Addr: guestAddr, Port: 7070}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatalf("guest ListenTCP: %v", err)
	}
	defer guestLn.Close()

	payload := bytes.Repeat([]byte("A"), 256*1024)
	recvDone := make(chan int, 1)
	go func() {
		c, aerr := guestLn.Accept()
		if aerr != nil {
			recvDone <- -1
			return
		}
		defer c.Close()
		n, _ := io.Copy(io.Discard, c)
		recvDone <- int(n)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	hc, err := eng.DialGuestTCP(ctx, guestNetIPStr, 7070)
	if err != nil {
		t.Fatalf("DialGuestTCP failed: %v", err)
	}
	if _, err := hc.Write(payload); err != nil {
		_ = hc.Close()
		t.Fatalf("hc.Write failed: %v", err)
	}
	_ = hc.Close()

	select {
	case n := <-recvDone:
		if n != len(payload) {
			t.Fatalf("expected %d bytes over jumbo TCP, got %d", len(payload), n)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for jumbo TCP receive")
	}

	// 2. Verify guest-side FirnFSServer RPC over 10.89.0.1:2385.
	fsConn, err := gonet.DialContextTCP(ctx, guestStack, tcpip.FullAddress{NIC: nicID, Addr: hostAddr, Port: 2385}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatalf("guest DialContextTCP to firnfs failed: %v", err)
	}
	defer fsConn.Close()

	var reqPayload bytes.Buffer
	writeShortStr(&reqPayload, "sample.bin")
	var frame [9]byte
	binary.BigEndian.PutUint32(frame[0:4], 42)
	frame[4] = fsOpLookup
	binary.BigEndian.PutUint32(frame[5:9], uint32(reqPayload.Len()))
	if _, err := fsConn.Write(append(frame[:], reqPayload.Bytes()...)); err != nil {
		t.Fatalf("write firnfs lookup failed: %v", err)
	}
	var respHdr [9]byte
	if _, err := io.ReadFull(fsConn, respHdr[:]); err != nil {
		t.Fatalf("read firnfs hdr failed: %v", err)
	}
	if gotID := binary.BigEndian.Uint32(respHdr[0:4]); gotID != 42 {
		t.Fatalf("expected reqID 42, got %d", gotID)
	}
	respLen := binary.BigEndian.Uint32(respHdr[5:9])
	respBody := make([]byte, respLen)
	if _, err := io.ReadFull(fsConn, respBody); err != nil {
		t.Fatalf("read firnfs body failed: %v", err)
	}
	if len(respBody) < 68 || binary.BigEndian.Uint32(respBody[0:4]) != 0 {
		t.Fatalf("unexpected firnfs lookup body len=%d", len(respBody))
	}
	if gotSz := binary.BigEndian.Uint64(respBody[12:20]); gotSz != uint64(len("firn-jumbo-payload")) {
		t.Fatalf("expected sample.bin size %d, got %d", len("firn-jumbo-payload"), gotSz)
	}
	if eng.rawEP.Capabilities()&stack.CapabilityRXChecksumOffload == 0 {
		t.Fatal("expected dgramL2Endpoint to enable CapabilityRXChecksumOffload")
	}
}
