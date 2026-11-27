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
