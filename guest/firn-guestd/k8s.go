package main

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultK3sVersion   = "v1.31.6+k3s1"
	k3sDataDir          = "/var/lib/firn/k3s"
	k3sBinPath          = "/var/lib/firn/k3s/bin/k3s"
	k3sEnabledMarker    = "/var/lib/firn/k3s/enabled"
	k3sKubeconfigPath   = "/var/lib/firn/k3s/kubeconfig.yaml"
	k3sCgroupPath       = "/sys/fs/cgroup/firn-k3s"
	k3sDefaultAPIPort   = 6443
	k3sLogPath          = "/var/log/firn/k3s.log"
)

type K3sStatus struct {
	Enabled             bool   `json:"enabled"`
	Running             bool   `json:"running"`
	Ready               bool   `json:"ready"`
	Version             string `json:"version"`
	BinaryInstalled     bool   `json:"binaryInstalled"`
	APIPort             int    `json:"apiPort"`
	NodeName            string `json:"nodeName"`
	MemoryBytes         uint64 `json:"memoryBytes"`
	Frozen              bool   `json:"frozen"`
	KubeconfigAvailable bool   `json:"kubeconfigAvailable"`
}

type K8sServiceInfo struct {
	Name        string   `json:"name"`
	Namespace   string   `json:"namespace"`
	ClusterIP   string   `json:"clusterIp"`
	Type        string   `json:"type"`
	Ports       []int    `json:"ports"`
	PrimaryPort int      `json:"primaryPort"`
	DNSNames    []string `json:"dnsNames"`
}

type K3sManager struct {
	mu      sync.Mutex
	domain  string
	cmd     *exec.Cmd
	pid     int
	version string

	svcMu       sync.Mutex
	svcCachedAt time.Time
	svcCache    []K8sServiceInfo
	dnsCache    []DNSRecord
}

func NewK3sManager(domain string) *K3sManager {
	if domain == "" {
		domain = "firn.local"
	}
	ver := os.Getenv("FIRN_K3S_VERSION")
	if ver == "" {
		ver = defaultK3sVersion
	}
	return &K3sManager{
		domain:  domain,
		version: ver,
	}
}

func (m *K3sManager) SetDomain(domain string) {
	if domain == "" {
		return
	}
	m.mu.Lock()
	m.domain = domain
	m.mu.Unlock()
}

func (m *K3sManager) IsEnabled() bool {
	_, err := os.Stat(k3sEnabledMarker)
	return err == nil
}

func (m *K3sManager) IsRunning() bool {
	m.mu.Lock()
	pid := m.pid
	m.mu.Unlock()
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func (m *K3sManager) Status() K3sStatus {
	m.mu.Lock()
	pid := m.pid
	ver := m.version
	m.mu.Unlock()

	running := pid > 0 && syscall.Kill(pid, 0) == nil
	_, binErr := os.Stat(k3sBinPath)
	_, kcErr := os.Stat(k3sKubeconfigPath)
	mem := readUint64File(filepath.Join(k3sCgroupPath, "memory.current"))
	frozen := readCgroupFrozen(k3sCgroupPath)

	ready := false
	if running {
		ready = probeK3sAPIReady(2 * time.Second)
	}

	return K3sStatus{
		Enabled:             m.IsEnabled(),
		Running:             running,
		Ready:               ready,
		Version:             ver,
		BinaryInstalled:     binErr == nil,
		APIPort:             k3sDefaultAPIPort,
		NodeName:            "firn",
		MemoryBytes:         mem,
		Frozen:              frozen,
		KubeconfigAvailable: kcErr == nil,
	}
}

func (m *K3sManager) MaybeAutoStart() {
	if !m.IsEnabled() {
		return
	}
	go func() {
		_, _ = m.Enable()
	}()
}

func k3sDownloadURL(version string) string {
	archSuffix := "arm64"
	if runtime.GOARCH == "amd64" {
		archSuffix = ""
	}
	escaped := strings.ReplaceAll(version, "+", "%2B")
	if archSuffix == "" {
		return fmt.Sprintf("https://github.com/k3s-io/k3s/releases/download/%s/k3s", escaped)
	}
	return fmt.Sprintf("https://github.com/k3s-io/k3s/releases/download/%s/k3s-%s", escaped, archSuffix)
}

func (m *K3sManager) ensureBinary() error {
	if fi, err := os.Stat(k3sBinPath); err == nil && fi.Size() > 10*1024*1024 {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(k3sBinPath), 0o755); err != nil {
		return err
	}
	downloadURL := k3sDownloadURL(m.version)
	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Get(downloadURL)
	if err != nil {
		return fmt.Errorf("download k3s (%s): %w", downloadURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download k3s HTTP %d from %s", resp.StatusCode, downloadURL)
	}
	tmpPath := k3sBinPath + ".tmp"
	f, err := os.OpenFile(tmpPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(f, resp.Body)
	closeErr := f.Close()
	if copyErr != nil {
		_ = os.Remove(tmpPath)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmpPath)
		return closeErr
	}
	return os.Rename(tmpPath, k3sBinPath)
}

func (m *K3sManager) Enable() (K3sStatus, error) {
	if err := m.ensureBinary(); err != nil {
		return m.Status(), err
	}
	if err := os.MkdirAll(k3sDataDir, 0o755); err != nil {
		return m.Status(), err
	}
	_ = os.WriteFile(k3sEnabledMarker, []byte(m.version+"\n"), 0o644)
	// Ensure k3s uses Firn's built-in OCI pull-through mirror when enabled.
	if _, serr := os.Stat(filepath.Join(defaultRegistryCacheDir, "disabled")); os.IsNotExist(serr) {
		regContent := fmt.Sprintf("mirrors:\n  \"docker.io\":\n    endpoint:\n      - %q\n", defaultRegistryMirrorURL)
		_ = os.MkdirAll(filepath.Dir(defaultK3sRegistriesYAMLPath), 0o755)
		_ = os.WriteFile(defaultK3sRegistriesYAMLPath, []byte(regContent), 0o644)
	}

	m.mu.Lock()
	if m.pid > 0 && syscall.Kill(m.pid, 0) == nil {
		m.mu.Unlock()
		return m.Status(), nil
	}
	dom := m.domain
	m.mu.Unlock()

	_ = os.MkdirAll(k3sCgroupPath, 0o755)
	_ = writeSysfsControl(filepath.Join(k3sCgroupPath, "cgroup.freeze"), []byte("0\n"))

	logFile, err := os.OpenFile(k3sLogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		logFile = nil
	}

	args := []string{
		"server",
		"--data-dir", k3sDataDir,
		"--write-kubeconfig", k3sKubeconfigPath,
		"--write-kubeconfig-mode", "0644",
		"--tls-san", "127.0.0.1",
		"--tls-san", "localhost",
		"--tls-san", "k8s." + dom,
		"--https-listen-port", strconv.Itoa(k3sDefaultAPIPort),
		"--disable", "traefik",
		"--disable", "servicelb",
		"--node-name", "firn",
		"--kubelet-arg=cgroup-driver=cgroupfs",
		"--flannel-backend=host-gw",
		"--snapshotter=overlayfs",
	}
	cmd := exec.Command(k3sBinPath, args...)
	if logFile != nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	}
	cmd.Env = append(os.Environ(), "K3S_NODE_NAME=firn")
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			_ = logFile.Close()
		}
		return m.Status(), err
	}

	pid := cmd.Process.Pid
	_ = writeSysfsControl(filepath.Join(k3sCgroupPath, "cgroup.procs"), []byte(strconv.Itoa(pid)+"\n"))

	m.mu.Lock()
	m.cmd = cmd
	m.pid = pid
	m.mu.Unlock()

	go func(c *exec.Cmd, lf *os.File) {
		_ = c.Wait()
		if lf != nil {
			_ = lf.Close()
		}
		m.mu.Lock()
		if m.cmd == c {
			m.cmd = nil
			m.pid = 0
		}
		m.mu.Unlock()
	}(cmd, logFile)

	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if !m.IsRunning() {
			return m.Status(), fmt.Errorf("k3s exited during startup; inspect %s", k3sLogPath)
		}
		if probeK3sAPIReady(2 * time.Second) {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	ensureK3sNatRules()
	m.invalidateServiceCache()
	return m.Status(), nil
}

func (m *K3sManager) Disable() (K3sStatus, error) {
	m.invalidateServiceCache()
	_ = os.Remove(k3sEnabledMarker)
	m.mu.Lock()
	pid := m.pid
	m.mu.Unlock()
	if pid > 0 {
		_ = writeSysfsControl(filepath.Join(k3sCgroupPath, "cgroup.freeze"), []byte("0\n"))
		_ = syscall.Kill(pid, syscall.SIGTERM)
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			if syscall.Kill(pid, 0) != nil {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		if syscall.Kill(pid, 0) == nil {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	}
	return m.Status(), nil
}

func (m *K3sManager) Reset(keepBinary bool) (K3sStatus, error) {
	_, _ = m.Disable()
	if keepBinary {
		entries, _ := os.ReadDir(k3sDataDir)
		for _, ent := range entries {
			if ent.Name() == "bin" {
				continue
			}
			_ = os.RemoveAll(filepath.Join(k3sDataDir, ent.Name()))
		}
	} else {
		_ = os.RemoveAll(k3sDataDir)
	}
	return m.Status(), nil
}

func (m *K3sManager) Freeze() error {
	return writeSysfsControl(filepath.Join(k3sCgroupPath, "cgroup.freeze"), []byte("1\n"))
}

func (m *K3sManager) Thaw() error {
	return writeSysfsControl(filepath.Join(k3sCgroupPath, "cgroup.freeze"), []byte("0\n"))
}

func rewriteKubeconfigForFirn(raw string) string {
	lines := strings.Split(raw, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "server:") {
			indent := line[:len(line)-len(strings.TrimLeft(line, " "))]
			out = append(out, indent+fmt.Sprintf("server: https://127.0.0.1:%d", k3sDefaultAPIPort))
			continue
		}
		if strings.HasPrefix(trimmed, "current-context:") {
			out = append(out, "current-context: firn")
			continue
		}
		if trimmed == "name: default" || trimmed == "- name: default" || trimmed == "cluster: default" || trimmed == "user: default" {
			out = append(out, strings.Replace(line, "default", "firn", 1))
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func (m *K3sManager) Kubeconfig() (string, error) {
	raw, err := os.ReadFile(k3sKubeconfigPath)
	if err != nil {
		return "", err
	}
	return rewriteKubeconfigForFirn(string(raw)), nil
}

func loadKubeconfigClientCert(path string) (tls.Certificate, bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return tls.Certificate{}, false
	}
	var certB64, keyB64 string
	for _, line := range strings.Split(string(raw), "\n") {
		trimmed := strings.TrimSpace(line)
		if val, ok := strings.CutPrefix(trimmed, "client-certificate-data:"); ok {
			certB64 = strings.Trim(strings.TrimSpace(val), "\"'")
		} else if val, ok := strings.CutPrefix(trimmed, "client-key-data:"); ok {
			keyB64 = strings.Trim(strings.TrimSpace(val), "\"'")
		}
	}
	if certB64 == "" || keyB64 == "" {
		return tls.Certificate{}, false
	}
	certPEM, err1 := base64.StdEncoding.DecodeString(certB64)
	keyPEM, err2 := base64.StdEncoding.DecodeString(keyB64)
	if err1 != nil || err2 != nil {
		return tls.Certificate{}, false
	}
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, false
	}
	return pair, true
}

func probeK3sAPIReady(timeout time.Duration) bool {
	cert, ok := loadKubeconfigClientCert(k3sKubeconfigPath)
	if !ok {
		return false
	}
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
			Certificates:       []tls.Certificate{cert},
		},
	}
	client := &http.Client{Transport: tr, Timeout: timeout}
	resp, err := client.Get(fmt.Sprintf("https://127.0.0.1:%d/readyz", k3sDefaultAPIPort))
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode == http.StatusOK && strings.Contains(string(body), "ok")
}

func (s K3sStatus) ToJSON() []byte {
	b, _ := json.Marshal(s)
	return b
}

func (m *K3sManager) invalidateServiceCache() {
	m.svcMu.Lock()
	m.svcCachedAt = time.Time{}
	m.svcCache = nil
	m.dnsCache = nil
	m.svcMu.Unlock()
}

func ensureK3sNatRules() {
	if _, err := exec.LookPath("iptables"); err != nil {
		return
	}
	rules := [][]string{
		{"-t", "nat", "POSTROUTING", "-s", "10.89.0.1/32", "-d", "10.42.0.0/16", "-j", "MASQUERADE"},
		{"-t", "nat", "POSTROUTING", "-s", "10.89.0.1/32", "-d", "10.43.0.0/16", "-j", "MASQUERADE"},
		{"FORWARD", "-s", "10.89.0.1/32", "-d", "10.42.0.0/16", "-j", "ACCEPT"},
		{"FORWARD", "-s", "10.89.0.1/32", "-d", "10.43.0.0/16", "-j", "ACCEPT"},
		{"FORWARD", "-d", "10.89.0.1/32", "-s", "10.42.0.0/16", "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT"},
	}
	for _, spec := range rules {
		var tableArgs, chainAndRule []string
		if spec[0] == "-t" {
			tableArgs = spec[:2]
			chainAndRule = spec[2:]
		} else {
			chainAndRule = spec
		}
		checkArgs := append(append([]string{}, tableArgs...), append([]string{"-C"}, chainAndRule...)...)
		if exec.Command("iptables", checkArgs...).Run() == nil {
			continue
		}
		verb := "-A"
		if len(tableArgs) == 0 {
			verb = "-I"
			chainAndRule = append([]string{chainAndRule[0], "1"}, chainAndRule[1:]...)
		}
		addArgs := append(append([]string{}, tableArgs...), append([]string{verb}, chainAndRule...)...)
		_ = exec.Command("iptables", addArgs...).Run()
	}
}

type rawK8sServiceList struct {
	Items []struct {
		Metadata struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			ClusterIP string `json:"clusterIP"`
			Type      string `json:"type"`
			Ports     []struct {
				Name     string `json:"name"`
				Port     int    `json:"port"`
				Protocol string `json:"protocol"`
			} `json:"ports"`
		} `json:"spec"`
	} `json:"items"`
}

type rawK8sIngressList struct {
	Items []struct {
		Metadata struct {
			Namespace string `json:"namespace"`
		} `json:"metadata"`
		Spec struct {
			Rules []struct {
				Host string `json:"host"`
				HTTP *struct {
					Paths []struct {
						Backend struct {
							Service *struct {
								Name string `json:"name"`
								Port struct {
									Name   string `json:"name"`
									Number int    `json:"number"`
								} `json:"port"`
							} `json:"service"`
						} `json:"backend"`
					} `json:"paths"`
				} `json:"http"`
			} `json:"rules"`
		} `json:"spec"`
	} `json:"items"`
}

func k3sHTTPClient(timeout time.Duration) *http.Client {
	cert, ok := loadKubeconfigClientCert(k3sKubeconfigPath)
	if !ok {
		return nil
	}
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				InsecureSkipVerify: true,
				Certificates:       []tls.Certificate{cert},
			},
		},
	}
}

func pickK8sPrimaryPort(ports []int) int {
	for _, pref := range []int{80, 8080, 3000, 8000, 443, 8443} {
		for _, p := range ports {
			if p == pref {
				return p
			}
		}
	}
	if len(ports) > 0 {
		return ports[0]
	}
	return 0
}

func buildK8sDiscovery(svcRaw, ingRaw []byte, domain string) ([]K8sServiceInfo, []DNSRecord) {
	domain = strings.TrimSuffix(strings.ToLower(domain), ".")
	if domain == "" {
		domain = "firn.local"
	}
	var sl rawK8sServiceList
	if len(svcRaw) > 0 {
		_ = json.Unmarshal(svcRaw, &sl)
	}
	var il rawK8sIngressList
	if len(ingRaw) > 0 {
		_ = json.Unmarshal(ingRaw, &il)
	}

	type svcLookupKey struct{ ns, name string }
	type svcPortMeta struct {
		info     *K8sServiceInfo
		byName   map[string]int
		byNumber map[int]bool
	}
	byKey := make(map[svcLookupKey]*svcPortMeta)
	services := make([]K8sServiceInfo, 0, len(sl.Items))

	for _, item := range sl.Items {
		ns := strings.TrimSpace(item.Metadata.Namespace)
		name := strings.TrimSpace(item.Metadata.Name)
		cip := strings.TrimSpace(item.Spec.ClusterIP)
		if ns == "" || name == "" || cip == "" || strings.EqualFold(cip, "None") {
			continue
		}
		if ns == "default" && name == "kubernetes" {
			continue
		}
		var tcpPorts []int
		byName := make(map[string]int)
		byNum := make(map[int]bool)
		for _, p := range item.Spec.Ports {
			if p.Port <= 0 || (p.Protocol != "" && strings.ToUpper(p.Protocol) != "TCP") {
				continue
			}
			if !byNum[p.Port] {
				tcpPorts = append(tcpPorts, p.Port)
				byNum[p.Port] = true
			}
			if p.Name != "" {
				byName[p.Name] = p.Port
			}
		}
		if len(tcpPorts) == 0 {
			continue
		}
		dnsNames := []string{
			sanitizeDNSLabel(name) + "." + sanitizeDNSLabel(ns) + ".k8s." + domain,
		}
		if ns == "default" {
			dnsNames = append(dnsNames, sanitizeDNSLabel(name)+".k8s."+domain)
		}
		info := K8sServiceInfo{
			Name:        name,
			Namespace:   ns,
			ClusterIP:   cip,
			Type:        item.Spec.Type,
			Ports:       tcpPorts,
			PrimaryPort: pickK8sPrimaryPort(tcpPorts),
			DNSNames:    dnsNames,
		}
		services = append(services, info)
		idx := len(services) - 1
		byKey[svcLookupKey{ns: ns, name: name}] = &svcPortMeta{
			info:     &services[idx],
			byName:   byName,
			byNumber: byNum,
		}
	}

	// Merge Kubernetes Ingress host rules pointing into ClusterIP services.
	var records []DNSRecord
	ingMatched := make(map[svcLookupKey]bool)
	for _, ing := range il.Items {
		ns := strings.TrimSpace(ing.Metadata.Namespace)
		for _, rule := range ing.Spec.Rules {
			host := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(rule.Host)), ".")
			if host == "" || rule.HTTP == nil {
				continue
			}
			for _, p := range rule.HTTP.Paths {
				if p.Backend.Service == nil {
					continue
				}
				meta := byKey[svcLookupKey{ns: ns, name: p.Backend.Service.Name}]
				if meta == nil {
					continue
				}
				targetPort := meta.info.PrimaryPort
				if p.Backend.Service.Port.Number > 0 {
					targetPort = p.Backend.Service.Port.Number
				} else if p.Backend.Service.Port.Name != "" {
					if named, ok := meta.byName[p.Backend.Service.Port.Name]; ok {
						targetPort = named
					}
				}
				dup := false
				for _, ex := range meta.info.DNSNames {
					if ex == host {
						dup = true
						break
					}
				}
				if !dup && (host == domain || strings.HasSuffix(host, "."+domain)) {
					meta.info.DNSNames = append(meta.info.DNSNames, host)
					if targetPort != meta.info.PrimaryPort && targetPort > 0 {
						records = append(records, DNSRecord{
							Names:         []string{host},
							ContainerName: "k8s-" + ns + "-" + meta.info.Name,
							Project:       "k8s",
							Service:       meta.info.Name,
							IP:            meta.info.ClusterIP,
							HTTPPort:      targetPort,
						})
						ingMatched[svcLookupKey{ns: ns, name: meta.info.Name}] = true
					}
				}
			}
		}
	}

	sort.Slice(services, func(i, j int) bool {
		if services[i].Namespace != services[j].Namespace {
			return services[i].Namespace < services[j].Namespace
		}
		return services[i].Name < services[j].Name
	})

	for _, svc := range services {
		_ = ingMatched
		if len(svc.DNSNames) == 0 || svc.PrimaryPort <= 0 {
			continue
		}
		records = append(records, DNSRecord{
			Names:         svc.DNSNames,
			ContainerName: "k8s-" + svc.Namespace + "-" + svc.Name,
			Project:       "k8s",
			Service:       svc.Name,
			IP:            svc.ClusterIP,
			HTTPPort:      svc.PrimaryPort,
		})
	}
	return services, records
}

func (m *K3sManager) discover(domain string) ([]K8sServiceInfo, []DNSRecord) {
	if !m.IsRunning() {
		return nil, nil
	}
	if domain == "" {
		m.mu.Lock()
		domain = m.domain
		m.mu.Unlock()
	}
	m.svcMu.Lock()
	if !m.svcCachedAt.IsZero() && time.Since(m.svcCachedAt) < 1500*time.Millisecond {
		svcs := append([]K8sServiceInfo(nil), m.svcCache...)
		recs := append([]DNSRecord(nil), m.dnsCache...)
		m.svcMu.Unlock()
		return svcs, recs
	}
	m.svcMu.Unlock()

	client := k3sHTTPClient(2 * time.Second)
	if client == nil {
		return nil, nil
	}
	readEndpoint := func(path string) []byte {
		resp, err := client.Get(fmt.Sprintf("https://127.0.0.1:%d%s", k3sDefaultAPIPort, path))
		if err != nil {
			return nil
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil
		}
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		return raw
	}
	svcRaw := readEndpoint("/api/v1/services")
	ingRaw := readEndpoint("/apis/networking.k8s.io/v1/ingresses")
	svcs, recs := buildK8sDiscovery(svcRaw, ingRaw, domain)

	m.svcMu.Lock()
	m.svcCachedAt = time.Now()
	m.svcCache = append([]K8sServiceInfo(nil), svcs...)
	m.dnsCache = append([]DNSRecord(nil), recs...)
	m.svcMu.Unlock()
	return svcs, recs
}

func (m *K3sManager) DiscoverServices(domain string) []K8sServiceInfo {
	svcs, _ := m.discover(domain)
	return svcs
}

func (m *K3sManager) DiscoverDNSRecords(domain string) []DNSRecord {
	_, recs := m.discover(domain)
	return recs
}

func (m *K3sManager) LoadImages(images []string) (string, error) {
	cleaned := make([]string, 0, len(images))
	for _, img := range images {
		trimmed := strings.TrimSpace(img)
		if trimmed != "" {
			cleaned = append(cleaned, trimmed)
		}
	}
	if len(cleaned) == 0 {
		return "", fmt.Errorf("at least one image reference is required")
	}
	if !m.IsRunning() {
		return "", fmt.Errorf("k3s is not running; run `firn k8s enable` first")
	}

	saveArgs := append([]string{"save"}, cleaned...)
	saveCmd := exec.Command("docker", saveArgs...)
	importCmd := exec.Command(k3sBinPath, "ctr", "-n", "k8s.io", "images", "import", "-")

	pr, pw, err := os.Pipe()
	if err != nil {
		return "", err
	}
	var saveErrBuf, importOutBuf bytes.Buffer
	saveCmd.Stdout = pw
	saveCmd.Stderr = &saveErrBuf
	importCmd.Stdin = pr
	importCmd.Stdout = &importOutBuf
	importCmd.Stderr = &importOutBuf

	if err := saveCmd.Start(); err != nil {
		_ = pr.Close()
		_ = pw.Close()
		return "", fmt.Errorf("start docker save: %w", err)
	}
	_ = pw.Close()
	if err := importCmd.Start(); err != nil {
		_ = pr.Close()
		_ = saveCmd.Wait()
		return "", fmt.Errorf("start k3s ctr import: %w", err)
	}
	_ = pr.Close()

	saveErr := saveCmd.Wait()
	importErr := importCmd.Wait()
	out := strings.TrimSpace(importOutBuf.String())
	if saveErr != nil {
		return out, fmt.Errorf("docker save failed: %w (%s)", saveErr, strings.TrimSpace(saveErrBuf.String()))
	}
	if importErr != nil {
		return out, fmt.Errorf("k3s image import failed: %w (%s)", importErr, out)
	}
	m.invalidateServiceCache()
	return out, nil
}
