package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestRegistryCacheAuthManifestAndBlobCaching(t *testing.T) {
	blobBytes := []byte("firn-oci-blob-payload-0123456789")
	blobSum := sha256.Sum256(blobBytes)
	blobDigest := "sha256:" + hex.EncodeToString(blobSum[:])
	manifestBody := []byte(fmt.Sprintf(`{"schemaVersion":2,"layers":[{"digest":%q,"size":%d}]}`, blobDigest, len(blobBytes)))
	manSum := sha256.Sum256(manifestBody)
	manDigest := "sha256:" + hex.EncodeToString(manSum[:])

	var tokenHits, manifestHits, blobHits atomic.Int32
	var upstream *httptest.Server
	upstream = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/token":
			tokenHits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"token":"mock-jwt-token","expires_in":300}`))
		case strings.HasPrefix(r.URL.Path, "/v2/library/alpine/manifests/"):
			if r.Header.Get("Authorization") != "Bearer mock-jwt-token" {
				w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="registry.test",scope="repository:library/alpine:pull"`, upstream.URL))
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			manifestHits.Add(1)
			w.Header().Set("Content-Type", "application/vnd.oci.image.manifest.v1+json")
			w.Header().Set("Docker-Content-Digest", manDigest)
			w.Header().Set("ETag", `"etag-1"`)
			_, _ = w.Write(manifestBody)
		case r.URL.Path == "/v2/library/alpine/blobs/"+blobDigest:
			if r.Header.Get("Authorization") != "Bearer mock-jwt-token" {
				w.Header().Set("WWW-Authenticate", fmt.Sprintf(`Bearer realm="%s/token",service="registry.test",scope="repository:library/alpine:pull"`, upstream.URL))
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			blobHits.Add(1)
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Header().Set("Docker-Content-Digest", blobDigest)
			if r.Method != http.MethodHead {
				_, _ = w.Write(blobBytes)
			}
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	daemonPath := filepath.Join(dir, "daemon.json")
	k3sPath := filepath.Join(dir, "registries.yaml")
	_ = os.WriteFile(daemonPath, []byte(`{"storage-driver":"overlay2"}`), 0o644)

	rc := NewRegistryCache(filepath.Join(dir, "cache"), "127.0.0.1:0", nil, false)
	rc.daemonJSONPath = daemonPath
	rc.k3sRegistriesPath = k3sPath
	rc.cfg.Upstream = upstream.URL
	if err := rc.Start(); err != nil {
		t.Fatalf("RegistryCache.Start failed: %v", err)
	}
	defer rc.Stop()

	mirrorURL := rc.ListenURL()
	cli := &http.Client{}

	// /v2/ ping
	resp, err := cli.Get(mirrorURL + "/v2/")
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /v2/ failed: resp=%v err=%v", resp, err)
	}
	_ = resp.Body.Close()

	// Manifest MISS -> HIT
	for i := range 2 {
		req, _ := http.NewRequest(http.MethodGet, mirrorURL+"/v2/library/alpine/manifests/3.21", nil)
		req.Header.Set("Accept", "application/vnd.oci.image.manifest.v1+json")
		mr, merr := cli.Do(req)
		if merr != nil || mr.StatusCode != http.StatusOK {
			t.Fatalf("manifest req %d failed: %v err=%v", i, mr, merr)
		}
		got, _ := io.ReadAll(mr.Body)
		_ = mr.Body.Close()
		if string(got) != string(manifestBody) {
			t.Fatalf("manifest body mismatch")
		}
		wantHdr := "MISS"
		if i == 1 {
			wantHdr = "HIT"
		}
		if mr.Header.Get("X-Firn-Cache") != wantHdr {
			t.Fatalf("manifest iter %d expected X-Firn-Cache=%s, got %q", i, wantHdr, mr.Header.Get("X-Firn-Cache"))
		}
	}

	// Blob MISS -> HIT + HEAD HIT
	for i := range 2 {
		br, berr := cli.Get(mirrorURL + "/v2/library/alpine/blobs/" + blobDigest)
		if berr != nil || br.StatusCode != http.StatusOK {
			t.Fatalf("blob req %d failed: %v err=%v", i, br, berr)
		}
		got, _ := io.ReadAll(br.Body)
		_ = br.Body.Close()
		if string(got) != string(blobBytes) {
			t.Fatalf("blob body mismatch")
		}
		wantHdr := "MISS"
		if i == 1 {
			wantHdr = "HIT"
		}
		if br.Header.Get("X-Firn-Cache") != wantHdr {
			t.Fatalf("blob iter %d expected X-Firn-Cache=%s, got %q", i, wantHdr, br.Header.Get("X-Firn-Cache"))
		}
	}

	headReq, _ := http.NewRequest(http.MethodHead, mirrorURL+"/v2/library/alpine/blobs/"+blobDigest, nil)
	hr, herr := cli.Do(headReq)
	if herr != nil || hr.StatusCode != http.StatusOK || hr.Header.Get("X-Firn-Cache") != "HIT" {
		t.Fatalf("blob HEAD hit failed: resp=%v err=%v", hr, herr)
	}
	_ = hr.Body.Close()

	if manifestHits.Load() != 1 || blobHits.Load() != 1 || tokenHits.Load() != 1 {
		t.Fatalf("expected exactly 1 upstream fetch per resource and 1 token fetch, got token=%d manifest=%d blob=%d",
			tokenHits.Load(), manifestHits.Load(), blobHits.Load())
	}

	st := rc.Status()
	if !st.Enabled || !st.Listening || st.BlobCount != 1 || st.ManifestCount != 1 || st.Hits < 3 || st.Misses != 2 {
		t.Fatalf("unexpected cache status: %+v", st)
	}

	// Config sync + Disable/Enable toggle
	if err := rc.syncMirrorConfigs(true); err != nil {
		t.Fatal(err)
	}
	rawDaemon, _ := os.ReadFile(daemonPath)
	var dObj map[string]any
	_ = json.Unmarshal(rawDaemon, &dObj)
	if dObj["data-root"] != "/var/lib/firn/docker" || dObj["registry-mirrors"] == nil {
		t.Fatalf("expected daemon.json mirror & data-root written, got %s", string(rawDaemon))
	}

	if _, err := rc.Prune(true); err != nil {
		t.Fatal(err)
	}
	if stAfter := rc.Status(); stAfter.BlobCount != 0 || stAfter.ManifestCount != 0 {
		t.Fatalf("expected 0 items after Prune(true), got %+v", stAfter)
	}
}
