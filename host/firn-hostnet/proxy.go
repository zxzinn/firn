package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type PortMappingEntry struct {
	HostPort      int    `json:"hostPort"`
	GuestPort     int    `json:"guestPort"`
	GuestHost     string `json:"guestHost"`
	Project       string `json:"project,omitempty"`
	Service       string `json:"service"`
	ContainerName string `json:"containerName"`
	ContainerIP   string `json:"containerIP,omitempty"`
	Paused        bool   `json:"paused"`
}

type DNSRecordEntry struct {
	Names         []string `json:"names"`
	ContainerName string   `json:"containerName"`
	Project       string   `json:"project,omitempty"`
	Service       string   `json:"service"`
	IP            string   `json:"ip"`
	HTTPPort      int      `json:"httpPort,omitempty"`
	Paused        bool     `json:"paused"`
}

type TopologyUpdatePayload struct {
	Version    uint64             `json:"version"`
	Domain     string             `json:"domain"`
	Hibernated bool               `json:"hibernated"`
	Ports      []PortMappingEntry `json:"ports"`
	Records    []DNSRecordEntry   `json:"records"`
}

type ProxyManagerConfig struct {
	Domain            string
	HTTPPort          uint16
	HTTPSPort         uint16
	CACert            string
	CAKey             string
	FirndSock         string
	Engine            *NetEngine
	EnablePortForward bool
}

type ProxyManager struct {
	cfg ProxyManagerConfig

	mu          sync.RWMutex
	hibernated  bool
	domain      string
	ports       map[int]PortMappingEntry
	listeners   map[int][]net.Listener
	records     []DNSRecordEntry
	ipIndex     map[string]DNSRecordEntry
	hostIndex   map[string]DNSRecordEntry
	portByCont  map[string][]PortMappingEntry

	caMu       sync.Mutex
	caCert     *x509.Certificate
	caKey      any
	caModTime  time.Time
	leafCache  map[string]*tls.Certificate

	httpSrvs   []*http.Server
	httpsSrvs  []*http.Server
	httpProxy  *httputil.ReverseProxy
	wakeMu     sync.Mutex
	closed     bool
}

func NewProxyManager(cfg ProxyManagerConfig) *ProxyManager {
	if cfg.Domain == "" {
		cfg.Domain = "firn.local"
	}
	pm := &ProxyManager{
		cfg:        cfg,
		domain:     cfg.Domain,
		ports:      make(map[int]PortMappingEntry),
		listeners:  make(map[int][]net.Listener),
		ipIndex:    make(map[string]DNSRecordEntry),
		hostIndex:  make(map[string]DNSRecordEntry),
		portByCont: make(map[string][]PortMappingEntry),
		leafCache:  make(map[string]*tls.Certificate),
	}

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, portStr, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			if host == "127.0.0.1" {
				return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, addr)
			}
			var portNum uint16
			_, _ = fmt.Sscanf(portStr, "%d", &portNum)
			return pm.dialWithFallback(ctx, host, portNum)
		},
		MaxIdleConns:          128,
		MaxIdleConnsPerHost:   64,
		IdleConnTimeout:       45 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ExpectContinueTimeout: time.Second,
		DisableCompression:    true,
	}

	pm.httpProxy = &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			target, ok := pr.In.Context().Value(targetCtxKey{}).(resolvedTarget)
			if ok {
				pr.SetURL(&url.URL{Scheme: "http", Host: fmt.Sprintf("%s:%d", target.ip, target.port)})
				pr.Out.Host = pr.In.Host
				pr.SetXForwarded()
			}
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "Bad Gateway: "+err.Error(), http.StatusBadGateway)
		},
	}

	return pm
}

type targetCtxKey struct{}

type resolvedTarget struct {
	ip   string
	port int
}

func (pm *ProxyManager) dialWithFallback(ctx context.Context, ip string, port uint16) (net.Conn, error) {
	c, err := pm.cfg.Engine.DialGuestTCP(ctx, ip, port)
	if err == nil {
		return c, nil
	}
	if ip != guestNetIPStr {
		if fb, fbErr := pm.cfg.Engine.DialGuestTCP(ctx, guestNetIPStr, port); fbErr == nil {
			return fb, nil
		}
	}
	return nil, err
}

func (pm *ProxyManager) Start() error {
	handler := http.HandlerFunc(pm.serveDomainHTTP)
	for _, host := range []string{"127.0.0.1", "[::1]"} {
		if pm.cfg.HTTPPort > 0 {
			ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", host, pm.cfg.HTTPPort))
			if err == nil {
				srv := &http.Server{
					Handler:           handler,
					ReadHeaderTimeout: 10 * time.Second,
					IdleTimeout:       60 * time.Second,
				}
				pm.httpSrvs = append(pm.httpSrvs, srv)
				go func(l net.Listener, s *http.Server) {
					_ = s.Serve(l)
				}(ln, srv)
			}
		}
		if pm.cfg.HTTPSPort > 0 {
			tlsCfg := &tls.Config{
				MinVersion:               tls.VersionTLS12,
				NextProtos:               []string{"http/1.1"},
				GetCertificate:           pm.getLeafCertificate,
				PreferServerCipherSuites: false,
			}
			ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", host, pm.cfg.HTTPSPort))
			if err == nil {
				srv := &http.Server{
					Handler:           handler,
					TLSConfig:         tlsCfg,
					ReadHeaderTimeout: 10 * time.Second,
					IdleTimeout:       60 * time.Second,
				}
				pm.httpsSrvs = append(pm.httpsSrvs, srv)
				go func(l net.Listener, s *http.Server) {
					_ = s.ServeTLS(l, "", "")
				}(ln, srv)
			}
		}
	}
	if len(pm.httpsSrvs) == 0 && pm.cfg.HTTPSPort > 0 {
		return fmt.Errorf("failed binding loopback HTTPS proxy on :%d", pm.cfg.HTTPSPort)
	}
	return nil
}

func (pm *ProxyManager) serveDomainHTTP(w http.ResponseWriter, r *http.Request) {
	hostHeader := strings.TrimSuffix(strings.ToLower(strings.Split(r.Host, ":")[0]), ".")
	if hostHeader == "" {
		http.Error(w, "Missing Host header", http.StatusBadRequest)
		return
	}
	pm.mu.RLock()
	rec, ok := pm.hostIndex[hostHeader]
	hib := pm.hibernated
	var fallbackHostPort int
	if ok {
		for _, p := range pm.portByCont[rec.ContainerName] {
			if p.GuestPort == rec.HTTPPort {
				fallbackHostPort = p.HostPort
				break
			}
		}
	}
	pm.mu.RUnlock()

	if !ok || rec.HTTPPort <= 0 {
		http.Error(w, fmt.Sprintf("Unknown local domain: %s\n", r.Host), http.StatusNotFound)
		return
	}

	if hib {
		pm.ensureResumed()
	}
	if rec.Paused && rec.Project != "" {
		triggerThawHost(pm.cfg.FirndSock, rec.Project, rec.ContainerName)
		pm.markUnpausedLocal(rec.Project)
	}

	destIP := rec.IP
	destPort := rec.HTTPPort
	if fallbackHostPort > 0 {
		destIP = "127.0.0.1"
		destPort = fallbackHostPort
	} else if destIP == "" {
		destIP = guestNetIPStr
	}

	ctx := context.WithValue(r.Context(), targetCtxKey{}, resolvedTarget{ip: destIP, port: destPort})
	pm.httpProxy.ServeHTTP(w, r.WithContext(ctx))
}

func (pm *ProxyManager) ApplyTopology(upd TopologyUpdatePayload) {
	desiredPorts := make(map[int]PortMappingEntry, len(upd.Ports))
	byCont := make(map[string][]PortMappingEntry)
	for _, p := range upd.Ports {
		if p.HostPort > 0 && p.HostPort <= 65535 {
			desiredPorts[p.HostPort] = p
			byCont[p.ContainerName] = append(byCont[p.ContainerName], p)
		}
	}
	ipIdx := make(map[string]DNSRecordEntry, len(upd.Records))
	hostIdx := make(map[string]DNSRecordEntry, len(upd.Records)*2)
	for _, rec := range upd.Records {
		if rec.IP != "" {
			ipIdx[rec.IP] = rec
		}
		for _, name := range rec.Names {
			hostIdx[strings.ToLower(name)] = rec
		}
	}

	pm.mu.Lock()
	if pm.closed {
		pm.mu.Unlock()
		return
	}
	if upd.Domain != "" {
		pm.domain = upd.Domain
	}
	pm.hibernated = upd.Hibernated
	for port, lns := range pm.listeners {
		if _, keep := desiredPorts[port]; !keep {
			for _, l := range lns {
				_ = l.Close()
			}
			delete(pm.listeners, port)
		}
	}
	pm.ports = desiredPorts
	pm.records = upd.Records
	pm.ipIndex = ipIdx
	pm.hostIndex = hostIdx
	pm.portByCont = byCont

	var toOpen []int
	if pm.cfg.EnablePortForward {
		for port := range desiredPorts {
			if len(pm.listeners[port]) == 0 {
				toOpen = append(toOpen, port)
			}
		}
	}
	pm.mu.Unlock()

	for _, port := range toOpen {
		lns := bindDualStackLoopbackTCP(port)
		if len(lns) == 0 {
			continue
		}
		pm.mu.Lock()
		if pm.closed || pm.ports[port].HostPort == 0 {
			pm.mu.Unlock()
			for _, l := range lns {
				_ = l.Close()
			}
			continue
		}
		pm.listeners[port] = lns
		pm.mu.Unlock()
		for _, ln := range lns {
			go pm.acceptPortLoop(port, ln)
		}
	}
}

func bindDualStackLoopbackTCP(port int) []net.Listener {
	var out []net.Listener
	for _, host := range []string{"127.0.0.1", "[::1]"} {
		ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", host, port))
		if err == nil {
			out = append(out, ln)
		}
	}
	return out
}

func (pm *ProxyManager) acceptPortLoop(hostPort int, ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
			_ = tc.SetReadBuffer(1 << 20)
			_ = tc.SetWriteBuffer(1 << 20)
		}
		go pm.handleAcceptedTCP(hostPort, c)
	}
}

func (pm *ProxyManager) handleAcceptedTCP(hostPort int, client net.Conn) {
	pm.mu.RLock()
	entry, ok := pm.ports[hostPort]
	hib := pm.hibernated
	pm.mu.RUnlock()
	if !ok {
		_ = client.Close()
		return
	}
	if hib {
		pm.ensureResumed()
	}
	if entry.Paused && entry.Project != "" {
		triggerThawHost(pm.cfg.FirndSock, entry.Project, entry.ContainerName)
		pm.markUnpausedLocal(entry.Project)
	}
	destIP := entry.ContainerIP
	destPort := uint16(entry.GuestPort)
	if destIP == "" {
		destIP = guestNetIPStr
		destPort = uint16(entry.HostPort)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	up, err := pm.dialWithFallback(ctx, destIP, destPort)
	cancel()
	if err != nil {
		_ = client.Close()
		return
	}
	spliceDual(client, up)
}

func (pm *ProxyManager) markUnpausedLocal(project string) {
	pm.mu.Lock()
	for p, entry := range pm.ports {
		if entry.Project == project && entry.Paused {
			entry.Paused = false
			pm.ports[p] = entry
		}
	}
	for k, rec := range pm.ipIndex {
		if rec.Project == project && rec.Paused {
			rec.Paused = false
			pm.ipIndex[k] = rec
		}
	}
	for k, rec := range pm.hostIndex {
		if rec.Project == project && rec.Paused {
			rec.Paused = false
			pm.hostIndex[k] = rec
		}
	}
	pm.mu.Unlock()
}

func (pm *ProxyManager) LookupPausedByIP(ip string) (string, string, bool) {
	pm.mu.RLock()
	defer pm.mu.RUnlock()
	if rec, ok := pm.ipIndex[ip]; ok {
		return rec.Project, rec.ContainerName, rec.Paused
	}
	return "", "", false
}

func (pm *ProxyManager) ensureResumed() {
	pm.wakeMu.Lock()
	defer pm.wakeMu.Unlock()
	pm.mu.RLock()
	hib := pm.hibernated
	pm.mu.RUnlock()
	if !hib || pm.cfg.FirndSock == "" {
		return
	}
	_, _ = postUnixHTTP(pm.cfg.FirndSock, "POST", "/resume", nil, 30*time.Second)
	pm.mu.Lock()
	pm.hibernated = false
	pm.mu.Unlock()
}

func (pm *ProxyManager) getLeafCertificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	sni := strings.ToLower(strings.TrimSuffix(hello.ServerName, "."))
	if sni == "" {
		pm.mu.RLock()
		dom := pm.domain
		pm.mu.RUnlock()
		sni = "*." + dom
	}

	caCert, caKey, genChanged, err := pm.ensureCALoaded()
	if err != nil {
		return nil, err
	}

	pm.caMu.Lock()
	defer pm.caMu.Unlock()
	if genChanged {
		pm.leafCache = make(map[string]*tls.Certificate)
	}
	if cached, ok := pm.leafCache[sni]; ok {
		return cached, nil
	}

	leaf, err := mintLeafCert(caCert, caKey, sni, pm.domain)
	if err != nil {
		return nil, err
	}
	pm.leafCache[sni] = leaf
	return leaf, nil
}

func (pm *ProxyManager) ensureCALoaded() (*x509.Certificate, any, bool, error) {
	pm.caMu.Lock()
	defer pm.caMu.Unlock()
	fi, err := os.Stat(pm.cfg.CACert)
	if err != nil {
		return nil, nil, false, err
	}
	if pm.caCert != nil && !fi.ModTime().After(pm.caModTime) {
		return pm.caCert, pm.caKey, false, nil
	}
	certPEM, err := os.ReadFile(pm.cfg.CACert)
	if err != nil {
		return nil, nil, false, err
	}
	keyPEM, err := os.ReadFile(pm.cfg.CAKey)
	if err != nil {
		return nil, nil, false, err
	}
	certBlock, _ := pem.Decode(certPEM)
	if certBlock == nil {
		return nil, nil, false, fmt.Errorf("invalid CA cert PEM")
	}
	caCert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, nil, false, err
	}
	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		return nil, nil, false, fmt.Errorf("invalid CA key PEM")
	}
	var caKey any
	if k, err := x509.ParseECPrivateKey(keyBlock.Bytes); err == nil {
		caKey = k
	} else if k, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes); err == nil {
		caKey = k
	} else if k, err := x509.ParsePKCS1PrivateKey(keyBlock.Bytes); err == nil {
		caKey = k
	} else {
		return nil, nil, false, fmt.Errorf("unsupported CA private key format")
	}
	pm.caCert = caCert
	pm.caKey = caKey
	pm.caModTime = fi.ModTime()
	return caCert, caKey, true, nil
}

func mintLeafCert(caCert *x509.Certificate, caKey any, sni string, baseDomain string) (*tls.Certificate, error) {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serialLimit := new(big.Int).Lsh(big.NewInt(1), 62)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		serial = big.NewInt(time.Now().UnixNano())
	}
	if baseDomain == "" {
		baseDomain = "firn.local"
	}
	cleanBase := strings.Trim(strings.ToLower(baseDomain), ".")
	sans := []string{cleanBase, "*." + cleanBase}
	seen := map[string]bool{cleanBase: true, "*." + cleanBase: true}
	addSAN := func(name string) {
		if name != "" && !seen[name] {
			seen[name] = true
			sans = append(sans, name)
		}
	}
	if !strings.HasPrefix(sni, "*.") {
		addSAN(sni)
	}
	parts := strings.Split(sni, ".")
	if len(parts) >= 3 {
		addSAN("*." + strings.Join(parts[1:], "."))
	}

	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   sni,
			Organization: []string{"Firn"},
		},
		NotBefore:             time.Now().Add(-5 * time.Minute),
		NotAfter:              time.Now().Add(825 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              sans,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &priv.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	leafParsed, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, err
	}
	return &tls.Certificate{
		Certificate: [][]byte{der, caCert.Raw},
		PrivateKey:  priv,
		Leaf:        leafParsed,
	}, nil
}

func (pm *ProxyManager) Close() {
	pm.mu.Lock()
	pm.closed = true
	lnsMap := pm.listeners
	pm.listeners = make(map[int][]net.Listener)
	pm.mu.Unlock()

	for _, lns := range lnsMap {
		for _, l := range lns {
			_ = l.Close()
		}
	}
	for _, srv := range append(pm.httpSrvs, pm.httpsSrvs...) {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		_ = srv.Shutdown(ctx)
		cancel()
	}
}

func triggerThawHost(firndSock, project, container string) {
	if firndSock == "" || project == "" {
		return
	}
	path := "/thaw/" + url.PathEscape(project)
	if container != "" {
		path += "?target=" + url.QueryEscape(container)
	}
	_, _ = postUnixHTTP(firndSock, "POST", path, nil, 15*time.Second)
}

func postUnixHTTP(sockPath, method, path string, body []byte, timeout time.Duration) (int, error) {
	dialer := &net.Dialer{Timeout: timeout}
	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return dialer.DialContext(ctx, "unix", sockPath)
			},
		},
	}
	var req *http.Request
	var err error
	if body != nil {
		req, err = http.NewRequest(method, "http://firn"+path, strings.NewReader(string(body)))
	} else {
		req, err = http.NewRequest(method, "http://firn"+path, nil)
	}
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.StatusCode, nil
}

func serveControlSocket(
	ctx context.Context,
	sockPath string,
	engine *NetEngine,
	proxyMgr *ProxyManager,
	fsServer *FirnFSServer,
) error {
	_ = os.MkdirAll(filepath.Dir(sockPath), 0o755)
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return err
	}
	_ = os.Chmod(sockPath, 0o600)

	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(engine.Stats())
	})
	mux.HandleFunc("/topology", func(w http.ResponseWriter, r *http.Request) {
		var upd TopologyUpdatePayload
		if err := json.NewDecoder(r.Body).Decode(&upd); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		proxyMgr.ApplyTopology(upd)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/dns-servers", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Servers []string `json:"servers"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		engine.SetDNSServers(req.Servers)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/fsevents", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Paths []string `json:"paths"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		fsServer.BroadcastInvalidations(req.Paths)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})

	srv := &http.Server{Handler: mux}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
		_ = os.Remove(sockPath)
	}()
	go func() {
		_ = srv.Serve(ln)
	}()
	return nil
}
