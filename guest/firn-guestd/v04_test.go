package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestFirnFSCachePrefetchLRUAndInvalidate(t *testing.T) {
	cache := newFirnFSCache(1024, 3)
	cache.PutDirPrefetch("app", []fsDirPrefetchItem{
		{Name: "a.txt", Attr: fsAttrWire{Ino: 1, Size: 5, Mode: 0o100644}, HasData: true, Data: []byte("hello")},
		{Name: "b.txt", Attr: fsAttrWire{Ino: 2, Size: 5, Mode: 0o100644}, HasData: true, Data: []byte("world")},
	})

	items, ok := cache.GetDirPrefetch("app")
	if !ok || len(items) != 2 {
		t.Fatalf("expected 2 cached dir items, got ok=%v len=%d", ok, len(items))
	}
	attr, data, hasData, ok := cache.GetEntry("app/a.txt")
	if !ok || !hasData || attr.Size != 5 || string(data) != "hello" {
		t.Fatalf("unexpected GetEntry result: ok=%v hasData=%v attr=%+v data=%q", ok, hasData, attr, string(data))
	}

	// Eviction keeps cache bounded to maxEntries=3
	cache.PutEntry("app/c.txt", fsAttrWire{Ino: 3, Size: 3}, []byte("123"), true)
	cache.PutEntry("app/d.txt", fsAttrWire{Ino: 4, Size: 3}, []byte("456"), true)
	entries, _, _ := cache.Stats()
	if entries > 3 {
		t.Fatalf("expected cache entries <= 3, got %d", entries)
	}

	// Invalidation removes target and parent directory listing
	cache.InvalidatePath("app/a.txt")
	if _, _, _, exists := cache.GetEntry("app/a.txt"); exists {
		t.Fatal("expected invalidated entry to be evicted")
	}
	if _, dirOK := cache.GetDirPrefetch("app"); dirOK {
		t.Fatal("expected parent directory listing to be invalidated")
	}
}

func TestFirnFSClientRPCAndPushInvalidation(t *testing.T) {
	cSide, sSide := net.Pipe()
	defer cSide.Close()
	defer sSide.Close()

	var mu sync.Mutex
	var gotInval []string
	doneInval := make(chan struct{}, 1)

	client := newFirnFSClientWithConn(cSide, func(paths []string) {
		mu.Lock()
		gotInval = append(gotInval, paths...)
		mu.Unlock()
		select {
		case doneInval <- struct{}{}:
		default:
		}
	})
	defer client.Close()

	// Push an async invalidation frame (reqID == 0) + answer one request
	go func() {
		var invalPayload bytes.Buffer
		var cnt [2]byte
		binary.BigEndian.PutUint16(cnt[:], 1)
		invalPayload.Write(cnt[:])
		writeShortStr(&invalPayload, "src/main.ts")
		var pushHdr [9]byte
		pushHdr[4] = fsOpPushInvalidate
		binary.BigEndian.PutUint32(pushHdr[5:9], uint32(invalPayload.Len()))
		_, _ = sSide.Write(append(pushHdr[:], invalPayload.Bytes()...))

		var reqHdr [9]byte
		_, _ = sSide.Read(reqHdr[:])
		reqLen := binary.BigEndian.Uint32(reqHdr[5:9])
		if reqLen > 0 {
			tmp := make([]byte, reqLen)
			_, _ = sSide.Read(tmp)
		}
		var resp [4]byte
		binary.BigEndian.PutUint32(resp[:], 0)
		var respHdr [9]byte
		copy(respHdr[0:4], reqHdr[0:4])
		respHdr[4] = reqHdr[4]
		binary.BigEndian.PutUint32(respHdr[5:9], 4)
		_, _ = sSide.Write(append(respHdr[:], resp[:]...))
	}()

	var req bytes.Buffer
	writeShortStr(&req, "foo")
	resp, err := client.call(fsOpUnlink, req.Bytes())
	if err != nil || len(resp) != 4 {
		t.Fatalf("unexpected RPC response: resp=%x err=%v", resp, err)
	}
	select {
	case <-doneInval:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for push invalidation callback")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(gotInval) != 1 || gotInval[0] != "src/main.ts" {
		t.Fatalf("unexpected invalidated paths: %v", gotInval)
	}
}

func TestFirnFSCacheTargetedInvalidationAndLocalOps(t *testing.T) {
	cache := newFirnFSCache(64*1024*1024, 16384)
	// Populate 50 sibling directories x 100 files = 5,000 entries
	for d := 0; d < 50; d++ {
		dirRel := "proj/d" + string(rune('a'+d/26)) + string(rune('a'+d%26))
		items := make([]fsDirPrefetchItem, 100)
		for f := 0; f < 100; f++ {
			name := "file_" + string(rune('a'+f/26)) + string(rune('a'+f%26)) + ".dat"
			items[f] = fsDirPrefetchItem{
				Name:    name,
				Attr:    fsAttrWire{Ino: uint64(d*100 + f + 1), Size: 4, Mode: 0o100644},
				HasData: true,
				Data:    []byte("abcd"),
			}
		}
		cache.PutDirPrefetch(dirRel, items)
	}

	// Local create + absence checks keep directory complete without wiping siblings
	rwItems := []fsDirPrefetchItem{}
	cache.PutDirPrefetch("proj/rw", rwItems)
	if !cache.IsKnownAbsent("proj/rw", "new.txt") {
		t.Fatal("expected new.txt to be known absent inside empty cached rw dir")
	}
	cache.RecordLocalCreate("proj/rw", "new.txt", fsAttrWire{Ino: 99999, Size: 0, Mode: 0o100644})
	if cache.IsKnownAbsent("proj/rw", "new.txt") {
		t.Fatal("expected created file to no longer be known absent")
	}
	if !cache.IsKnownAbsent("proj/rw", "other.txt") {
		t.Fatal("expected unrelated filename in same dir to remain known absent")
	}
	cache.UpdateWriteAttr("proj/rw/new.txt", 4096, 123456)
	if attr, _, hasData, ok := cache.GetEntry("proj/rw/new.txt"); !ok || hasData || attr.Size != 4096 {
		t.Fatalf("unexpected UpdateWriteAttr result: ok=%v hasData=%v attr=%+v", ok, hasData, attr)
	}
	cache.RecordLocalRemove("proj/rw", "new.txt")
	if !cache.IsKnownAbsent("proj/rw", "new.txt") {
		t.Fatal("expected removed file to be known absent again")
	}

	// Subtree directory invalidation removes only proj/daa and leaves proj/dab intact
	cache.InvalidatePath("proj/daa")
	if _, _, _, exists := cache.GetEntry("proj/daa/file_aa.dat"); exists {
		t.Fatal("expected invalidated subtree entry to be evicted")
	}
	if _, _, _, exists := cache.GetEntry("proj/dab/file_aa.dat"); !exists {
		t.Fatal("expected sibling directory entry to survive targeted invalidation")
	}
}

func TestFirnFSCacheRecentLocalEcho(t *testing.T) {
	cache := newFirnFSCache(1024*1024, 1024)
	cache.PutDirPrefetch("work/rw", nil)
	cache.RecordLocalCreate("work/rw", "local.tmp", fsAttrWire{Ino: 101, Mode: 0o100644})
	now := time.Now().UnixNano()
	if !cache.IsRecentLocalEcho("work/rw/local.tmp", now) {
		t.Fatal("expected immediate echo for locally created path")
	}
	if cache.IsRecentLocalEcho("work/rw/external.txt", now) {
		t.Fatal("expected unrelated path not to match local echo filter")
	}
	if cache.IsRecentLocalEcho("work/rw/local.tmp", now+int64(250*time.Millisecond)) {
		t.Fatal("expected local echo window to expire after 250ms")
	}
}

func TestFirnFSClientPushPrefetch(t *testing.T) {
	cSide, sSide := net.Pipe()
	defer cSide.Close()
	defer sSide.Close()

	cache := newFirnFSCache(1024*1024, 1024)
	donePrefetch := make(chan string, 1)
	client := newFirnFSClientWithConn(cSide, nil)
	client.SetOnPrefetch(func(dirRel string, items []fsDirPrefetchItem) {
		cache.PutDirPrefetch(dirRel, items)
		donePrefetch <- dirRel
	})
	defer client.Close()

	go func() {
		var body bytes.Buffer
		writeShortStr(&body, "work/d00")
		var cnt [4]byte
		binary.BigEndian.PutUint32(cnt[:], 1)
		body.Write(cnt[:])
		writeShortStr(&body, "hello.txt")
		var rawAttr [64]byte
		binary.BigEndian.PutUint64(rawAttr[0:8], 77)
		binary.BigEndian.PutUint64(rawAttr[8:16], 5)
		binary.BigEndian.PutUint32(rawAttr[48:52], 0o100644)
		body.Write(rawAttr[:])
		body.WriteByte(1)
		var dlen [4]byte
		binary.BigEndian.PutUint32(dlen[:], 5)
		body.Write(dlen[:])
		body.WriteString("hello")

		var hdr [9]byte
		hdr[4] = fsOpPushPrefetch
		binary.BigEndian.PutUint32(hdr[5:9], uint32(body.Len()))
		_, _ = sSide.Write(append(hdr[:], body.Bytes()...))
	}()

	select {
	case dirRel := <-donePrefetch:
		if dirRel != "work/d00" {
			t.Fatalf("unexpected prefetch dirRel %q", dirRel)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for push prefetch")
	}
	attr, data, hasData, ok := cache.GetEntry("work/d00/hello.txt")
	if !ok || !hasData || attr.Ino != 77 || string(data) != "hello" {
		t.Fatalf("unexpected cached prefetch entry: ok=%v hasData=%v attr=%+v data=%q", ok, hasData, attr, string(data))
	}
}

func TestAdaptiveVsockSpliceHalfClose(t *testing.T) {
	a1, a2 := net.Pipe()
	b1, b2 := net.Pipe()
	defer a1.Close()
	defer a2.Close()
	defer b1.Close()
	defer b2.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		spliceHalfClose(a2, b1)
	}()

	// Stream >512 KiB (crosses bulk threshold) + small reverse reply
	payload := bytes.Repeat([]byte("V"), 768*1024)
	errCh := make(chan error, 1)
	go func() {
		_, err := a1.Write(payload)
		_ = a1.Close()
		errCh <- err
	}()

	got := make([]byte, len(payload))
	if _, err := io.ReadFull(b2, got); err != nil {
		t.Fatal(err)
	}
	_ = b2.Close()
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("bulk splice payload mismatch")
	}
	<-done
}

func TestK3sKubeconfigAndMachinesDNS(t *testing.T) {
	sampleKC := `apiVersion: v1
clusters:
- cluster:
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
users:
- name: default
`
	rewritten := rewriteKubeconfigForFirn(sampleKC)
	if !strings.Contains(rewritten, "current-context: firn") || strings.Contains(rewritten, "name: default") {
		t.Fatalf("unexpected rewritten kubeconfig:\n%s", rewritten)
	}

	d, img := resolveMachineImage("ubuntu", "")
	if d != "ubuntu" || img != "ubuntu:24.04" {
		t.Fatalf("unexpected distro resolution: %s / %s", d, img)
	}
	if _, err := sanitizeMachineName("dev-box_1"); err != nil {
		t.Fatalf("unexpected machine name validation error: %v", err)
	}

	ins := &dockerContainerInspect{}
	ins.State.Pid = 301
	ins.NetworkSettings.Networks = map[string]dockerNetworkEndpoint{"bridge": {IPAddress: "10.87.0.9"}}
	fd := &fakeDocker{
		containers: map[string]dockerContainerSummary{
			"cid-vm": {
				ID:     "cid-vm",
				Names:  []string{"/firn-machine-devbox"},
				State:  "running",
				Labels: map[string]string{machineLabel: "true", machineNameLabel: "devbox", machineDistroLabel: "alpine", machineImageLabel: "alpine:3.21", exemptLabel: "true"},
			},
		},
		inspects: map[string]*dockerContainerInspect{"cid-vm": ins},
	}
	eng := NewReaperEngine(fd, 600, "firn.local", nil)
	eng.procRoot = t.TempDir()
	eng.cgroupRoot = t.TempDir()
	topo, err := eng.RefreshTopology(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	foundMachineDNS := false
	for _, r := range topo.Records {
		for _, n := range r.Names {
			if n == "devbox.firn.local" {
				foundMachineDNS = true
			}
		}
	}
	if !foundMachineDNS {
		t.Fatalf("expected devbox.firn.local in topology records: %+v", topo.Records)
	}

	mux := buildControlMux(eng, NewProxyAndDNSRelay(eng), NewK3sManager("firn.local"), t.TempDir())
	req := httptest.NewRequest(http.MethodGet, "/machines", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 OK from /machines, got %d", rec.Code)
	}
	var mResp struct {
		Machines []LinuxMachineInfo `json:"machines"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&mResp); err != nil {
		t.Fatal(err)
	}
	if len(mResp.Machines) != 1 || mResp.Machines[0].Name != "devbox" || mResp.Machines[0].DNSName != "devbox.firn.local" {
		t.Fatalf("unexpected /machines response: %+v", mResp.Machines)
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	kcYAML := "apiVersion: v1\nusers:\n- name: default\n  user:\n    client-certificate-data: " +
		base64.StdEncoding.EncodeToString(certPEM) +
		"\n    client-key-data: " +
		base64.StdEncoding.EncodeToString(keyPEM) + "\n"
	kcPath := filepath.Join(t.TempDir(), "kubeconfig.yaml")
	if err := os.WriteFile(kcPath, []byte(kcYAML), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := loadKubeconfigClientCert(kcPath); !ok {
		t.Fatalf("expected loadKubeconfigClientCert to parse valid YAML client cert/key")
	}
}
