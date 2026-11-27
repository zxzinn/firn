package main

import (
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

type K3sManager struct {
	mu      sync.Mutex
	domain  string
	cmd     *exec.Cmd
	pid     int
	version string
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
	return m.Status(), nil
}

func (m *K3sManager) Disable() (K3sStatus, error) {
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
