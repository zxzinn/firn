package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	defaultRegistryCacheDir        = "/var/lib/firn/registry-cache"
	defaultRegistryCacheListenAddr = "127.0.0.1:5000"
	defaultRegistryMirrorURL       = "http://127.0.0.1:5000"
	defaultRegistryUpstream        = "https://registry-1.docker.io"
	defaultRegistryMaxBytes        = uint64(10 * 1024 * 1024 * 1024) // 10 GiB
	defaultDockerDaemonJSONPath    = "/etc/docker/daemon.json"
	defaultK3sRegistriesYAMLPath   = "/etc/rancher/k3s/registries.yaml"
	defaultManifestTTL             = 5 * time.Minute
)

var hex64Re = regexp.MustCompile(`^[a-f0-9]{64}$`)

type RegistryCacheConfig struct {
	Enabled    bool   `json:"enabled"`
	Upstream   string `json:"upstream"`
	MaxBytes   uint64 `json:"maxBytes"`
	ListenAddr string `json:"listenAddr,omitempty"`
}

type RegistryCacheStatus struct {
	Enabled       bool   `json:"enabled"`
	Listening     bool   `json:"listening"`
	MirrorURL     string `json:"mirrorUrl"`
	Upstream      string `json:"upstream"`
	MaxBytes      uint64 `json:"maxBytes"`
	UsedBytes     uint64 `json:"usedBytes"`
	BlobCount     int    `json:"blobCount"`
	ManifestCount int    `json:"manifestCount"`
	Hits          uint64 `json:"hits"`
	Misses        uint64 `json:"misses"`
	SavedBytes    uint64 `json:"savedBytes"`
}

type cachedAuthToken struct {
	token     string
	expiresAt time.Time
}

type manifestMeta struct {
	ContentType string    `json:"contentType"`
	Digest      string    `json:"digest,omitempty"`
	ETag        string    `json:"etag,omitempty"`
	FetchedAt   time.Time `json:"fetchedAt"`
}

type RegistryCache struct {
	baseDir           string
	listenAddr        string
	daemonJSONPath    string
	k3sRegistriesPath string
	dockerPIDPath     string
	relay             *ProxyAndDNSRelay
	syncDockerFiles   bool

	mu        sync.Mutex
	cfg       RegistryCacheConfig
	listening bool
	boundAddr string
	srv       *http.Server
	ln        net.Listener

	authMu     sync.Mutex
	tokenCache map[string]cachedAuthToken
	httpClient *http.Client

	inflightMu sync.Mutex
	inflight   map[string]*sync.WaitGroup

	hits       atomic.Uint64
	misses     atomic.Uint64
	savedBytes atomic.Uint64
}

func NewRegistryCache(baseDir, listenAddr string, relay *ProxyAndDNSRelay, syncDockerFiles bool) *RegistryCache {
	if baseDir == "" {
		baseDir = defaultRegistryCacheDir
	}
	if listenAddr == "" {
		listenAddr = defaultRegistryCacheListenAddr
	}
	rc := &RegistryCache{
		baseDir:           baseDir,
		listenAddr:        listenAddr,
		daemonJSONPath:    defaultDockerDaemonJSONPath,
		k3sRegistriesPath: defaultK3sRegistriesYAMLPath,
		dockerPIDPath:     "/var/run/docker.pid",
		relay:             relay,
		syncDockerFiles:   syncDockerFiles,
		tokenCache:        make(map[string]cachedAuthToken),
		inflight:          make(map[string]*sync.WaitGroup),
	}
	tr := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			if rc.relay != nil {
				pc := rc.relay.Config()
				proxyStr := pc.HTTPSProxy
				if proxyStr == "" {
					proxyStr = pc.HTTPProxy
				}
				if proxyStr != "" {
					if u, err := url.Parse(proxyStr); err == nil {
						host := req.URL.Hostname()
						if host != "127.0.0.1" && host != "localhost" && host != "::1" {
							return u, nil
						}
					}
				}
			}
			return http.ProxyFromEnvironment(req)
		},
		MaxIdleConns:          32,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	}
	rc.httpClient = &http.Client{
		Transport: tr,
		Timeout:   15 * time.Minute,
	}
	rc.cfg = rc.loadConfig()
	return rc
}

func (rc *RegistryCache) disabledMarkerPath() string {
	return filepath.Join(rc.baseDir, "disabled")
}

func (rc *RegistryCache) configPath() string {
	return filepath.Join(rc.baseDir, "config.json")
}

func (rc *RegistryCache) loadConfig() RegistryCacheConfig {
	cfg := RegistryCacheConfig{
		Enabled:    true,
		Upstream:   defaultRegistryUpstream,
		MaxBytes:   defaultRegistryMaxBytes,
		ListenAddr: rc.listenAddr,
	}
	if _, err := os.Stat(rc.disabledMarkerPath()); err == nil {
		cfg.Enabled = false
	}
	if raw, err := os.ReadFile(rc.configPath()); err == nil {
		var disk RegistryCacheConfig
		if json.Unmarshal(raw, &disk) == nil {
			if disk.Upstream != "" {
				cfg.Upstream = strings.TrimRight(disk.Upstream, "/")
			}
			if disk.MaxBytes > 0 {
				cfg.MaxBytes = disk.MaxBytes
			}
			if _, serr := os.Stat(rc.disabledMarkerPath()); serr != nil {
				cfg.Enabled = disk.Enabled
			}
		}
	}
	return cfg
}

func (rc *RegistryCache) saveConfigLocked() error {
	if err := os.MkdirAll(rc.baseDir, 0o755); err != nil {
		return err
	}
	if rc.cfg.Enabled {
		_ = os.Remove(rc.disabledMarkerPath())
	} else {
		_ = os.WriteFile(rc.disabledMarkerPath(), []byte("disabled\n"), 0o644)
	}
	raw, err := json.MarshalIndent(rc.cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(rc.configPath(), raw, 0o644)
}

func (rc *RegistryCache) Start() error {
	rc.mu.Lock()
	enabled := rc.cfg.Enabled
	listening := rc.listening
	addr := rc.listenAddr
	rc.mu.Unlock()

	if !enabled {
		return nil
	}
	if listening {
		return nil
	}
	if err := os.MkdirAll(filepath.Join(rc.baseDir, "blobs"), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(rc.baseDir, "manifests"), 0o755); err != nil {
		return err
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	srv := &http.Server{
		Handler:           rc,
		ReadHeaderTimeout: 15 * time.Second,
	}
	rc.mu.Lock()
	rc.ln = ln
	rc.srv = srv
	rc.boundAddr = ln.Addr().String()
	rc.listening = true
	boundAddr := rc.boundAddr
	upstream := rc.cfg.Upstream
	rc.mu.Unlock()

	if rc.syncDockerFiles {
		_ = rc.syncMirrorConfigs(true)
	}

	log.Printf("[firn-guestd] OCI registry pull-through cache listening on http://%s -> %s", boundAddr, upstream)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("[firn-guestd] registry cache server stopped: %v", err)
		}
		rc.mu.Lock()
		if rc.srv == srv {
			rc.listening = false
			rc.srv = nil
			rc.ln = nil
		}
		rc.mu.Unlock()
	}()
	return nil
}

func (rc *RegistryCache) Stop() {
	rc.mu.Lock()
	srv := rc.srv
	ln := rc.ln
	rc.listening = false
	rc.srv = nil
	rc.ln = nil
	rc.mu.Unlock()
	if srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = srv.Shutdown(ctx)
		cancel()
	}
	if ln != nil {
		_ = ln.Close()
	}
}

func (rc *RegistryCache) ListenURL() string {
	rc.mu.Lock()
	addr := rc.boundAddr
	if addr == "" {
		addr = rc.listenAddr
	}
	rc.mu.Unlock()
	return "http://" + addr
}

func (rc *RegistryCache) Enable() (RegistryCacheStatus, error) {
	rc.mu.Lock()
	rc.cfg.Enabled = true
	if err := rc.saveConfigLocked(); err != nil {
		rc.mu.Unlock()
		return rc.Status(), err
	}
	rc.mu.Unlock()

	if err := rc.Start(); err != nil {
		return rc.Status(), err
	}
	if rc.syncDockerFiles {
		_ = rc.syncMirrorConfigs(true)
		rc.reloadDockerd()
	}
	return rc.Status(), nil
}

func (rc *RegistryCache) Disable() (RegistryCacheStatus, error) {
	rc.mu.Lock()
	rc.cfg.Enabled = false
	if err := rc.saveConfigLocked(); err != nil {
		rc.mu.Unlock()
		return rc.Status(), err
	}
	rc.mu.Unlock()

	rc.Stop()
	if rc.syncDockerFiles {
		_ = rc.syncMirrorConfigs(false)
		rc.reloadDockerd()
	}
	return rc.Status(), nil
}

func (rc *RegistryCache) TotalBytes() uint64 {
	used, _, _ := rc.scanCacheDiskUsage()
	return used
}

func (rc *RegistryCache) scanCacheDiskUsage() (totalBytes uint64, blobCount int, manifestCount int) {
	_ = filepath.WalkDir(filepath.Join(rc.baseDir, "blobs"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasPrefix(d.Name(), ".tmp-") {
			return nil
		}
		if fi, serr := d.Info(); serr == nil {
			totalBytes += uint64(max(0, fi.Size()))
			blobCount++
		}
		return nil
	})
	_ = filepath.WalkDir(filepath.Join(rc.baseDir, "manifests"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasPrefix(d.Name(), ".tmp-") {
			return nil
		}
		if fi, serr := d.Info(); serr == nil {
			totalBytes += uint64(max(0, fi.Size()))
		}
		if strings.HasSuffix(d.Name(), ".body") {
			manifestCount++
		}
		return nil
	})
	return totalBytes, blobCount, manifestCount
}

func (rc *RegistryCache) Status() RegistryCacheStatus {
	rc.mu.Lock()
	cfg := rc.cfg
	listening := rc.listening
	bound := rc.boundAddr
	rc.mu.Unlock()
	if bound == "" {
		bound = rc.listenAddr
	}
	used, blobs, manifests := rc.scanCacheDiskUsage()
	return RegistryCacheStatus{
		Enabled:       cfg.Enabled,
		Listening:     listening,
		MirrorURL:     "http://" + bound,
		Upstream:      cfg.Upstream,
		MaxBytes:      cfg.MaxBytes,
		UsedBytes:     used,
		BlobCount:     blobs,
		ManifestCount: manifests,
		Hits:          rc.hits.Load(),
		Misses:        rc.misses.Load(),
		SavedBytes:    rc.savedBytes.Load(),
	}
}

func (rc *RegistryCache) Prune(all bool) (map[string]any, error) {
	beforeBytes, _, _ := rc.scanCacheDiskUsage()
	var removedBlobs, removedManifests int
	if all {
		manifestsDir := filepath.Join(rc.baseDir, "manifests")
		if ents, err := os.ReadDir(manifestsDir); err == nil {
			for _, ent := range ents {
				if strings.HasSuffix(ent.Name(), ".body") {
					removedManifests++
				}
				_ = os.RemoveAll(filepath.Join(manifestsDir, ent.Name()))
			}
		}
		blobsDir := filepath.Join(rc.baseDir, "blobs")
		_ = filepath.WalkDir(blobsDir, func(path string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				removedBlobs++
			}
			return nil
		})
		_ = os.RemoveAll(blobsDir)
		_ = os.MkdirAll(blobsDir, 0o755)
	} else {
		// Non-destructive prune clears stale/expired tag manifests and enforces maxBytes LRU limit.
		manifestsDir := filepath.Join(rc.baseDir, "manifests")
		if ents, err := os.ReadDir(manifestsDir); err == nil {
			for _, ent := range ents {
				if strings.HasSuffix(ent.Name(), ".meta.json") {
					metaPath := filepath.Join(manifestsDir, ent.Name())
					if raw, rerr := os.ReadFile(metaPath); rerr == nil {
						var m manifestMeta
						if json.Unmarshal(raw, &m) == nil && time.Since(m.FetchedAt) > defaultManifestTTL {
							stem := strings.TrimSuffix(metaPath, ".meta.json")
							_ = os.Remove(metaPath)
							_ = os.Remove(stem + ".body")
							removedManifests++
						}
					}
				}
			}
		}
		removedBlobs = rc.evictToBudget()
	}
	afterBytes, _, _ := rc.scanCacheDiskUsage()
	freed := uint64(0)
	if beforeBytes > afterBytes {
		freed = beforeBytes - afterBytes
	}
	return map[string]any{
		"ok":               true,
		"all":              all,
		"removedBlobs":     removedBlobs,
		"removedManifests": removedManifests,
		"freedBytes":       freed,
		"status":           rc.Status(),
	}, nil
}

func (rc *RegistryCache) evictToBudget() int {
	rc.mu.Lock()
	maxB := rc.cfg.MaxBytes
	rc.mu.Unlock()
	if maxB == 0 {
		return 0
	}
	type blobFile struct {
		path    string
		size    uint64
		modTime time.Time
	}
	var list []blobFile
	var total uint64
	_ = filepath.WalkDir(filepath.Join(rc.baseDir, "blobs"), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || strings.HasPrefix(d.Name(), ".tmp-") {
			return nil
		}
		if fi, serr := d.Info(); serr == nil {
			sz := uint64(max(0, fi.Size()))
			total += sz
			list = append(list, blobFile{path: path, size: sz, modTime: fi.ModTime()})
		}
		return nil
	})
	if total <= maxB {
		return 0
	}
	sort.Slice(list, func(i, j int) bool {
		return list[i].modTime.Before(list[j].modTime)
	})
	removed := 0
	for _, bf := range list {
		if total <= maxB {
			break
		}
		if os.Remove(bf.path) == nil {
			total -= bf.size
			removed++
		}
	}
	return removed
}

func (rc *RegistryCache) syncMirrorConfigs(enabled bool) error {
	if rc.daemonJSONPath != "" {
		var obj map[string]any
		if raw, err := os.ReadFile(rc.daemonJSONPath); err == nil {
			_ = json.Unmarshal(raw, &obj)
		}
		if obj == nil {
			obj = make(map[string]any)
		}
		obj["data-root"] = "/var/lib/firn/docker"
		if enabled {
			obj["registry-mirrors"] = []string{defaultRegistryMirrorURL}
		} else {
			delete(obj, "registry-mirrors")
		}
		if out, err := json.MarshalIndent(obj, "", "  "); err == nil {
			_ = os.MkdirAll(filepath.Dir(rc.daemonJSONPath), 0o755)
			_ = os.WriteFile(rc.daemonJSONPath, append(out, '\n'), 0o644)
		}
	}
	if rc.k3sRegistriesPath != "" {
		if enabled {
			content := fmt.Sprintf("mirrors:\n  \"docker.io\":\n    endpoint:\n      - %q\n", defaultRegistryMirrorURL)
			_ = os.MkdirAll(filepath.Dir(rc.k3sRegistriesPath), 0o755)
			_ = os.WriteFile(rc.k3sRegistriesPath, []byte(content), 0o644)
		} else {
			_ = os.Remove(rc.k3sRegistriesPath)
		}
	}
	return nil
}

func (rc *RegistryCache) reloadDockerd() {
	if rc.dockerPIDPath == "" {
		return
	}
	raw, err := os.ReadFile(rc.dockerPIDPath)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGHUP)
}

func (rc *RegistryCache) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed on pull-through mirror", http.StatusMethodNotAllowed)
		return
	}
	path := r.URL.Path
	w.Header().Set("Docker-Distribution-Api-Version", "registry/2.0")
	if path == "/v2" || path == "/v2/" {
		w.WriteHeader(http.StatusOK)
		return
	}
	if !strings.HasPrefix(path, "/v2/") {
		http.NotFound(w, r)
		return
	}
	rest := strings.TrimPrefix(path, "/v2/")
	if idx := strings.LastIndex(rest, "/blobs/"); idx > 0 {
		repo := rest[:idx]
		digest := rest[idx+len("/blobs/"):]
		rc.handleBlob(w, r, repo, digest)
		return
	}
	if idx := strings.LastIndex(rest, "/manifests/"); idx > 0 {
		repo := rest[:idx]
		ref := rest[idx+len("/manifests/"):]
		rc.handleManifest(w, r, repo, ref)
		return
	}
	http.NotFound(w, r)
}

func parseBearerChallenge(hdr string) (realm, service, scope string, ok bool) {
	if !strings.HasPrefix(strings.ToLower(hdr), "bearer ") {
		return "", "", "", false
	}
	params := hdr[len("Bearer "):]
	for _, part := range strings.Split(params, ",") {
		k, v, found := strings.Cut(strings.TrimSpace(part), "=")
		if !found {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), `"`)
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "realm":
			realm = v
		case "service":
			service = v
		case "scope":
			scope = v
		}
	}
	return realm, service, scope, realm != ""
}

func (rc *RegistryCache) fetchBearerToken(ctx context.Context, realm, service, scope string) (string, error) {
	cacheKey := realm + "|" + service + "|" + scope
	now := time.Now()
	rc.authMu.Lock()
	if cached, ok := rc.tokenCache[cacheKey]; ok && now.Before(cached.expiresAt) {
		tok := cached.token
		rc.authMu.Unlock()
		return tok, nil
	}
	rc.authMu.Unlock()

	u, err := url.Parse(realm)
	if err != nil {
		return "", err
	}
	q := u.Query()
	if service != "" {
		q.Set("service", service)
	}
	if scope != "" {
		q.Set("scope", scope)
	}
	u.RawQuery = q.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", err
	}
	resp, err := rc.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token endpoint returned HTTP %d", resp.StatusCode)
	}
	var payload struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&payload); err != nil {
		return "", err
	}
	tok := payload.Token
	if tok == "" {
		tok = payload.AccessToken
	}
	if tok == "" {
		return "", fmt.Errorf("empty token in auth response")
	}
	ttl := 300 * time.Second
	if payload.ExpiresIn > 30 {
		ttl = time.Duration(payload.ExpiresIn-15) * time.Second
	}
	rc.authMu.Lock()
	rc.tokenCache[cacheKey] = cachedAuthToken{token: tok, expiresAt: now.Add(ttl)}
	rc.authMu.Unlock()
	return tok, nil
}

func (rc *RegistryCache) doUpstreamRequest(ctx context.Context, method, upstreamPath string, extraHeaders http.Header) (*http.Response, error) {
	rc.mu.Lock()
	base := rc.cfg.Upstream
	rc.mu.Unlock()
	targetURL := base + upstreamPath

	makeReq := func(bearer string) (*http.Request, error) {
		req, err := http.NewRequestWithContext(ctx, method, targetURL, nil)
		if err != nil {
			return nil, err
		}
		for k, vals := range extraHeaders {
			for _, v := range vals {
				req.Header.Add(k, v)
			}
		}
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		return req, nil
	}

	req, err := makeReq("")
	if err != nil {
		return nil, err
	}
	resp, err := rc.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusUnauthorized {
		return resp, nil
	}
	challenge := resp.Header.Get("WWW-Authenticate")
	_ = resp.Body.Close()
	realm, service, scope, ok := parseBearerChallenge(challenge)
	if !ok {
		return nil, fmt.Errorf("upstream returned 401 without valid Bearer challenge")
	}
	tok, err := rc.fetchBearerToken(ctx, realm, service, scope)
	if err != nil {
		return nil, err
	}
	retryReq, err := makeReq(tok)
	if err != nil {
		return nil, err
	}
	return rc.httpClient.Do(retryReq)
}

func (rc *RegistryCache) blobFilePath(digest string) (hexDigest string, path string, ok bool) {
	alg, hexPart, found := strings.Cut(strings.ToLower(strings.TrimSpace(digest)), ":")
	if !found || alg != "sha256" || !hex64Re.MatchString(hexPart) {
		return "", "", false
	}
	return hexPart, filepath.Join(rc.baseDir, "blobs", hexPart[:2], hexPart), true
}

func (rc *RegistryCache) handleBlob(w http.ResponseWriter, r *http.Request, repo, digest string) {
	hexDigest, blobPath, valid := rc.blobFilePath(digest)
	if !valid {
		http.Error(w, "invalid blob digest", http.StatusBadRequest)
		return
	}

	serveCached := func(fi os.FileInfo) {
		f, err := os.Open(blobPath)
		if err != nil {
			return
		}
		defer f.Close()
		rc.hits.Add(1)
		rc.savedBytes.Add(uint64(max(0, fi.Size())))
		now := time.Now()
		_ = os.Chtimes(blobPath, now, now)
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Docker-Content-Digest", "sha256:"+hexDigest)
		w.Header().Set("X-Firn-Cache", "HIT")
		http.ServeContent(w, r, hexDigest, fi.ModTime(), f)
	}

	if fi, err := os.Stat(blobPath); err == nil && fi.Mode().IsRegular() {
		serveCached(fi)
		return
	}

	// Singleflight deduplication for parallel pulls of the same blob digest.
	if r.Method == http.MethodGet && r.Header.Get("Range") == "" {
		rc.inflightMu.Lock()
		waitWG, active := rc.inflight[hexDigest]
		if !active {
			waitWG = &sync.WaitGroup{}
			waitWG.Add(1)
			rc.inflight[hexDigest] = waitWG
			rc.inflightMu.Unlock()
			defer func() {
				waitWG.Done()
				rc.inflightMu.Lock()
				delete(rc.inflight, hexDigest)
				rc.inflightMu.Unlock()
			}()
		} else {
			rc.inflightMu.Unlock()
			waitWG.Wait()
			if fi, err := os.Stat(blobPath); err == nil && fi.Mode().IsRegular() {
				serveCached(fi)
				return
			}
		}
	}

	upHeaders := make(http.Header)
	if rng := r.Header.Get("Range"); rng != "" {
		upHeaders.Set("Range", rng)
	}
	upPath := fmt.Sprintf("/v2/%s/blobs/%s", repo, digest)
	resp, err := rc.doUpstreamRequest(r.Context(), r.Method, upPath, upHeaders)
	if err != nil {
		http.Error(w, "upstream blob fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	copyResponseHeaders(w.Header(), resp.Header)
	w.Header().Set("Docker-Distribution-Api-Version", "registry/2.0")
	w.Header().Set("X-Firn-Cache", "MISS")

	if r.Method == http.MethodHead || resp.StatusCode != http.StatusOK || r.Header.Get("Range") != "" {
		w.WriteHeader(resp.StatusCode)
		if r.Method != http.MethodHead {
			_, _ = io.Copy(w, resp.Body)
		}
		return
	}

	rc.misses.Add(1)
	if err := os.MkdirAll(filepath.Dir(blobPath), 0o755); err != nil {
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
		return
	}

	tmpFile, err := os.CreateTemp(filepath.Dir(blobPath), ".tmp-"+hexDigest[:12]+"-*")
	if err != nil {
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
		return
	}
	tmpPath := tmpFile.Name()
	keepTmp := false
	defer func() {
		if !keepTmp {
			_ = tmpFile.Close()
			_ = os.Remove(tmpPath)
		}
	}()

	hasher := sha256.New()
	var multi io.Writer = io.MultiWriter(w, tmpFile, hasher)
	w.WriteHeader(resp.StatusCode)

	buf := make([]byte, 256*1024)
	_, copyErr := io.CopyBuffer(multi, resp.Body, buf)
	closeErr := tmpFile.Close()
	if copyErr == nil && closeErr == nil && hex.EncodeToString(hasher.Sum(nil)) == hexDigest {
		if os.Rename(tmpPath, blobPath) == nil {
			keepTmp = true
			go rc.evictToBudget()
		}
	}
}

func (rc *RegistryCache) manifestPaths(repo, ref, acceptHeader string) (bodyPath, metaPath string, isDigest bool) {
	if hexPart, _, ok := rc.blobFilePath(ref); ok {
		stem := filepath.Join(rc.baseDir, "manifests", "digest-"+hexPart)
		return stem + ".body", stem + ".meta.json", true
	}
	accepts := strings.Split(acceptHeader, ",")
	for i := range accepts {
		accepts[i] = strings.TrimSpace(accepts[i])
	}
	sort.Strings(accepts)
	h := sha256.Sum256([]byte(repo + "|" + ref + "|" + strings.Join(accepts, ",")))
	stem := filepath.Join(rc.baseDir, "manifests", "tag-"+hex.EncodeToString(h[:16]))
	return stem + ".body", stem + ".meta.json", false
}

func (rc *RegistryCache) handleManifest(w http.ResponseWriter, r *http.Request, repo, ref string) {
	acceptHdr := r.Header.Get("Accept")
	bodyPath, metaPath, isDigest := rc.manifestPaths(repo, ref, acceptHdr)

	var cachedBody []byte
	var cachedMeta manifestMeta
	haveCached := false
	if b, berr := os.ReadFile(bodyPath); berr == nil {
		if mb, merr := os.ReadFile(metaPath); merr == nil && json.Unmarshal(mb, &cachedMeta) == nil {
			cachedBody = b
			haveCached = true
		}
	}

	writeManifest := func(status int, body []byte, meta manifestMeta, hitStatus string) {
		if meta.ContentType != "" {
			w.Header().Set("Content-Type", meta.ContentType)
		}
		if meta.Digest != "" {
			w.Header().Set("Docker-Content-Digest", meta.Digest)
		}
		if meta.ETag != "" {
			w.Header().Set("ETag", meta.ETag)
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Header().Set("X-Firn-Cache", hitStatus)
		w.WriteHeader(status)
		if r.Method != http.MethodHead {
			_, _ = w.Write(body)
		}
	}

	if haveCached && (isDigest || time.Since(cachedMeta.FetchedAt) < defaultManifestTTL) {
		rc.hits.Add(1)
		rc.savedBytes.Add(uint64(len(cachedBody)))
		writeManifest(http.StatusOK, cachedBody, cachedMeta, "HIT")
		return
	}

	upHeaders := make(http.Header)
	if acceptHdr != "" {
		upHeaders.Set("Accept", acceptHdr)
	}
	if haveCached && !isDigest && cachedMeta.ETag != "" {
		upHeaders.Set("If-None-Match", cachedMeta.ETag)
	}
	upPath := fmt.Sprintf("/v2/%s/manifests/%s", repo, ref)
	resp, err := rc.doUpstreamRequest(r.Context(), r.Method, upPath, upHeaders)
	if err != nil {
		if haveCached {
			rc.hits.Add(1)
			rc.savedBytes.Add(uint64(len(cachedBody)))
			writeManifest(http.StatusOK, cachedBody, cachedMeta, "STALE")
			return
		}
		http.Error(w, "upstream manifest fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified && haveCached {
		cachedMeta.FetchedAt = time.Now().UTC()
		if mraw, merr := json.Marshal(cachedMeta); merr == nil {
			_ = os.WriteFile(metaPath, mraw, 0o644)
		}
		rc.hits.Add(1)
		rc.savedBytes.Add(uint64(len(cachedBody)))
		writeManifest(http.StatusOK, cachedBody, cachedMeta, "REVALIDATED")
		return
	}

	if resp.StatusCode != http.StatusOK {
		copyResponseHeaders(w.Header(), resp.Header)
		w.Header().Set("Docker-Distribution-Api-Version", "registry/2.0")
		w.Header().Set("X-Firn-Cache", "MISS")
		w.WriteHeader(resp.StatusCode)
		if r.Method != http.MethodHead {
			_, _ = io.Copy(w, resp.Body)
		}
		return
	}

	if r.Method == http.MethodHead {
		copyResponseHeaders(w.Header(), resp.Header)
		w.Header().Set("Docker-Distribution-Api-Version", "registry/2.0")
		w.Header().Set("X-Firn-Cache", "MISS")
		w.WriteHeader(resp.StatusCode)
		return
	}

	bodyBytes, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		http.Error(w, "read manifest failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	var digestSum hash.Hash = sha256.New()
	_, _ = digestSum.Write(bodyBytes)
	computedDigest := "sha256:" + hex.EncodeToString(digestSum.Sum(nil))
	if expectedHex, _, ok := rc.blobFilePath(ref); ok {
		if !bytes.Equal([]byte(computedDigest), []byte("sha256:"+expectedHex)) {
			http.Error(w, "manifest digest mismatch", http.StatusBadGateway)
			return
		}
	}

	digestHdr := resp.Header.Get("Docker-Content-Digest")
	if digestHdr == "" {
		digestHdr = computedDigest
	}
	meta := manifestMeta{
		ContentType: resp.Header.Get("Content-Type"),
		Digest:      digestHdr,
		ETag:        resp.Header.Get("ETag"),
		FetchedAt:   time.Now().UTC(),
	}
	rc.misses.Add(1)
	if os.MkdirAll(filepath.Dir(bodyPath), 0o755) == nil {
		if os.WriteFile(bodyPath+".tmp", bodyBytes, 0o644) == nil {
			_ = os.Rename(bodyPath+".tmp", bodyPath)
		}
		if mraw, merr := json.Marshal(meta); merr == nil {
			if os.WriteFile(metaPath+".tmp", mraw, 0o644) == nil {
				_ = os.Rename(metaPath+".tmp", metaPath)
			}
		}
	}
	writeManifest(http.StatusOK, bodyBytes, meta, "MISS")
}

func copyResponseHeaders(dst, src http.Header) {
	for _, h := range []string{"Content-Type", "Content-Length", "Docker-Content-Digest", "ETag", "Accept-Ranges", "Content-Range"} {
		if v := src.Get(h); v != "" {
			dst.Set(h, v)
		}
	}
}
