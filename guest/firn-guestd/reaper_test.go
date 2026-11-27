package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

type fakeDocker struct {
	mu         sync.Mutex
	containers map[string]dockerContainerSummary
	inspects   map[string]*dockerContainerInspect
	df         DockerDFSummary
	paused     []string
	unpaused   []string
}

func (f *fakeDocker) SystemDF() (DockerDFSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.df, nil
}

func (f *fakeDocker) ListContainers() ([]dockerContainerSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]dockerContainerSummary, 0, len(f.containers))
	for _, c := range f.containers {
		out = append(out, c)
	}
	return out, nil
}

func (f *fakeDocker) InspectContainer(cid string) (*dockerContainerInspect, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	orig := f.inspects[cid]
	if orig == nil {
		return nil, nil
	}
	cp := *orig
	return &cp, nil
}

func (f *fakeDocker) PauseContainer(cid string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.paused = append(f.paused, cid)
	if ins := f.inspects[cid]; ins != nil {
		ins.State.Paused = true
	}
	c := f.containers[cid]
	c.State = "paused"
	f.containers[cid] = c
	return nil
}

func (f *fakeDocker) UnpauseContainer(cid string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.unpaused = append(f.unpaused, cid)
	if ins := f.inspects[cid]; ins != nil {
		ins.State.Paused = false
	}
	c := f.containers[cid]
	c.State = "running"
	f.containers[cid] = c
	return nil
}

func TestParseTunnelHeader(t *testing.T) {
	host := "127.0.0.1"
	buf := &bytes.Buffer{}
	buf.WriteByte(1)
	buf.WriteByte(byte(len(host)))
	buf.WriteString(host)
	_ = binary.Write(buf, binary.BigEndian, uint16(5432))

	parsedHost, port, err := parseTunnelHeader(buf)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if parsedHost != host || port != 5432 {
		t.Fatalf("got %q:%d want %q:5432", parsedHost, port, host)
	}
}

func TestReaperIdleDetectionAndExempt(t *testing.T) {
	root := t.TempDir()
	procRoot := filepath.Join(root, "proc")
	cgRoot := filepath.Join(root, "cgroup")

	setupProcCg := func(pid int, cid string, mem uint64, established bool) {
		pdir := filepath.Join(procRoot, strconv.Itoa(pid), "net")
		if err := os.MkdirAll(pdir, 0o755); err != nil {
			t.Fatal(err)
		}
		cgRel := filepath.Join("docker", cid)
		cgDir := filepath.Join(cgRoot, cgRel)
		if err := os.MkdirAll(cgDir, 0o755); err != nil {
			t.Fatal(err)
		}
		_ = os.WriteFile(filepath.Join(procRoot, strconv.Itoa(pid), "cgroup"), []byte("0::/"+cgRel+"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "memory.current"), []byte(strconv.FormatUint(mem, 10)+"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "memory.swap.current"), []byte("0\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "cpu.stat"), []byte("usage_usec 1000\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "cgroup.events"), []byte("frozen 0\n"), 0o644)
		tcp := "  sl local rem st\n"
		if established {
			tcp += "   0: 0100007F:1538 0100007F:C001 01 00000000:00000000\n"
		}
		_ = os.WriteFile(filepath.Join(pdir, "tcp"), []byte(tcp), 0o644)
		_ = os.WriteFile(filepath.Join(pdir, "tcp6"), []byte("  sl local rem st\n"), 0o644)
		_ = os.WriteFile(filepath.Join(pdir, "dev"), []byte("h1\nh2\n lo: 0 0 0 0 0 0 0 0 0\n eth0: 100 1 0 0 0 0 0 0 100\n"), 0o644)
	}

	setupProcCg(101, "cid-idle", 200*1024*1024, false)
	setupProcCg(102, "cid-busy", 128*1024*1024, true)
	setupProcCg(103, "cid-pg", 256*1024*1024, false)

	ins := func(pid int, hostPort, guestPort int) *dockerContainerInspect {
		d := &dockerContainerInspect{}
		d.State.Pid = pid
		d.NetworkSettings.Ports = map[string][]dockerPortBinding{
			strconv.Itoa(guestPort) + "/tcp": {{HostIP: "0.0.0.0", HostPort: strconv.Itoa(hostPort)}},
		}
		d.NetworkSettings.Networks = map[string]dockerNetworkEndpoint{"default": {IPAddress: "172.18.0.2"}}
		return d
	}

	fd := &fakeDocker{
		containers: map[string]dockerContainerSummary{
			"cid-idle": {ID: "cid-idle", Names: []string{"/wt-idle-redis-1"}, State: "running", Labels: map[string]string{composeProjectLabel: "wt-idle", composeServiceLabel: "redis"}},
			"cid-busy": {ID: "cid-busy", Names: []string{"/wt-busy-redis-1"}, State: "running", Labels: map[string]string{composeProjectLabel: "wt-busy", composeServiceLabel: "redis"}},
			"cid-pg":   {ID: "cid-pg", Names: []string{"/shared-postgres"}, State: "running", Labels: map[string]string{composeProjectLabel: "shared-postgres", composeServiceLabel: "postgres"}},
		},
		inspects: map[string]*dockerContainerInspect{
			"cid-idle": ins(101, 6380, 6379),
			"cid-busy": ins(102, 6381, 6379),
			"cid-pg":   ins(103, 5432, 5432),
		},
	}

	eng := NewReaperEngine(fd, 60, "firn.local", []string{"shared-postgres"})
	eng.procRoot = procRoot
	eng.cgroupRoot = cgRoot

	base := time.Unix(1000, 0)
	if frozen, err := eng.ReapIdleOnce(base); err != nil || len(frozen) != 0 {
		t.Fatalf("unexpected initial reap: %v %v", frozen, err)
	}
	frozen, err := eng.ReapIdleOnce(base.Add(90 * time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(frozen) != 1 || frozen[0].Project != "wt-idle" {
		t.Fatalf("expected only wt-idle frozen, got %+v", frozen)
	}
	if _, err := eng.ThawProject("wt-idle"); err != nil {
		t.Fatal(err)
	}
	if len(fd.unpaused) != 1 || fd.unpaused[0] != "cid-idle" {
		t.Fatalf("expected cid-idle unpaused, got %v", fd.unpaused)
	}
}

func TestPortAndDNSMapping(t *testing.T) {
	info := &dockerContainerInspect{}
	info.NetworkSettings.Ports = map[string][]dockerPortBinding{
		"8025/tcp": {{HostIP: "0.0.0.0", HostPort: "8026"}},
	}
	ports := extractContainerPorts(info, "demo-app-abc", "mailpit", "demo-app-abc-mailpit-1", "172.20.0.4", false)
	if len(ports) != 1 || ports[0].HostPort != 8026 {
		t.Fatalf("unexpected ports: %+v", ports)
	}
	names, httpPort := buildContainerDNSNames("demo-app-abc-mailpit-1", "mailpit", "demo-app-abc", "firn.local", ports)
	if httpPort != 8025 || len(names) < 2 {
		t.Fatalf("unexpected dns output names=%v port=%d", names, httpPort)
	}
	if len(names) < 2 || names[1] != "mailpit.demo-app-abc.firn.local" {
		t.Fatalf("expected firn.local FQDN, got %v", names)
	}
	if errors.Is(syscall.EAGAIN, nil) {
		t.Fatal("unreachable")
	}
}

func TestTopologyWaitAndBump(t *testing.T) {
	ins := &dockerContainerInspect{}
	ins.State.Pid = 101
	ins.NetworkSettings.Ports = map[string][]dockerPortBinding{
		"6379/tcp": {{HostIP: "127.0.0.1", HostPort: "6379"}},
	}
	ins.NetworkSettings.Networks = map[string]dockerNetworkEndpoint{"default": {IPAddress: "10.88.0.2"}}

	fd := &fakeDocker{
		containers: map[string]dockerContainerSummary{
			"cid-1": {ID: "cid-1", Names: []string{"/proj-redis-1"}, State: "running", Labels: map[string]string{composeProjectLabel: "proj", composeServiceLabel: "redis"}},
		},
		inspects: map[string]*dockerContainerInspect{"cid-1": ins},
	}
	eng := NewReaperEngine(fd, 60, "firn.local", nil)
	eng.procRoot = t.TempDir()
	eng.cgroupRoot = t.TempDir()

	initial, err := eng.RefreshTopology(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if initial.Version != 1 || len(initial.Ports) != 1 || initial.Ports[0].Paused {
		t.Fatalf("unexpected initial topology: %+v", initial)
	}

	type waitRes struct {
		resp TopologyResponse
		err  error
	}
	ch := make(chan waitRes, 1)
	go func() {
		r, werr := eng.WaitTopology(context.Background(), initial.Version, 2*time.Second)
		ch <- waitRes{resp: r, err: werr}
	}()

	time.Sleep(25 * time.Millisecond)
	if _, err := eng.FreezeProject("proj", false, false); err != nil {
		t.Fatal(err)
	}

	select {
	case out := <-ch:
		if out.err != nil {
			t.Fatalf("wait failed: %v", out.err)
		}
		if out.resp.Version <= initial.Version || len(out.resp.Ports) != 1 || !out.resp.Ports[0].Paused {
			t.Fatalf("expected updated paused topology, got %+v", out.resp)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("WaitTopology did not wake on RefreshTopology bump")
	}
}

func TestTopologyEmptyArraysAndHTTPLongPoll(t *testing.T) {
	emptyFD := &fakeDocker{
		containers: map[string]dockerContainerSummary{},
		inspects:   map[string]*dockerContainerInspect{},
	}
	eng := NewReaperEngine(emptyFD, 60, "firn.local", nil)
	eng.procRoot = t.TempDir()
	eng.cgroupRoot = t.TempDir()

	initial, err := eng.RefreshTopology(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(initial)
	if err != nil {
		t.Fatal(err)
	}
	body := string(raw)
	if !strings.Contains(body, `"ports":[]`) || !strings.Contains(body, `"records":[]`) {
		t.Fatalf("expected non-null empty arrays in JSON, got %s", body)
	}

	relay := NewProxyAndDNSRelay(eng)
	srv := httptest.NewServer(buildControlMux(eng, relay, NewK3sManager("firn.local"), t.TempDir()))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/topology?since=1&wait=1")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK from /topology?since=1&wait=1, got %d", resp.StatusCode)
	}
	respBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	var decoded TopologyResponse
	if err := json.Unmarshal(respBytes, &decoded); err != nil {
		t.Fatalf("expected valid JSON payload, got %q: %v", string(respBytes), err)
	}
	if decoded.Version != initial.Version || decoded.Ports == nil || decoded.Records == nil {
		t.Fatalf("unexpected decoded topology response: %+v", decoded)
	}
}

func TestPerProjectIdleLabelConfigAndTargetThaw(t *testing.T) {
	root := t.TempDir()
	procRoot := filepath.Join(root, "proc")
	cgRoot := filepath.Join(root, "cgroup")

	setupProc := func(pid int, cid string) {
		pdir := filepath.Join(procRoot, strconv.Itoa(pid), "net")
		_ = os.MkdirAll(pdir, 0o755)
		cgDir := filepath.Join(cgRoot, "docker", cid)
		_ = os.MkdirAll(cgDir, 0o755)
		_ = os.WriteFile(filepath.Join(procRoot, strconv.Itoa(pid), "cgroup"), []byte("0::/docker/"+cid+"\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "memory.current"), []byte("10485760\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "cpu.stat"), []byte("usage_usec 100\n"), 0o644)
		_ = os.WriteFile(filepath.Join(cgDir, "cgroup.events"), []byte("frozen 0\n"), 0o644)
		_ = os.WriteFile(filepath.Join(pdir, "tcp"), []byte("  sl local rem st\n"), 0o644)
		_ = os.WriteFile(filepath.Join(pdir, "tcp6"), []byte("  sl local rem st\n"), 0o644)
		_ = os.WriteFile(filepath.Join(pdir, "dev"), []byte("h1\nh2\n"), 0o644)
	}
	setupProc(201, "cid-fast")
	setupProc(202, "cid-fast-sibling")
	setupProc(203, "cid-zero")

	mkIns := func(pid int) *dockerContainerInspect {
		d := &dockerContainerInspect{}
		d.State.Pid = pid
		return d
	}

	fd := &fakeDocker{
		containers: map[string]dockerContainerSummary{
			"cid-fast":         {ID: "cid-fast", Names: []string{"/fast-redis-1"}, State: "running", Labels: map[string]string{composeProjectLabel: "fast", composeServiceLabel: "redis", idleLabel: "20"}},
			"cid-fast-sibling": {ID: "cid-fast-sibling", Names: []string{"/fast-web-1"}, State: "running", Labels: map[string]string{composeProjectLabel: "fast", composeServiceLabel: "web"}},
			"cid-zero":         {ID: "cid-zero", Names: []string{"/perm-db-1"}, State: "running", Labels: map[string]string{composeProjectLabel: "perm", composeServiceLabel: "db", idleLabel: "0"}},
		},
		inspects: map[string]*dockerContainerInspect{
			"cid-fast":         mkIns(201),
			"cid-fast-sibling": mkIns(202),
			"cid-zero":         mkIns(203),
		},
	}

	eng := NewReaperEngine(fd, 600, "firn.local", nil)
	eng.procRoot = procRoot
	eng.cgroupRoot = cgRoot
	eng.ApplyConfig(300, "firn.test", []string{"extra-exempt"})
	if eng.Domain() != "firn.test" {
		t.Fatalf("expected updated domain firn.test, got %s", eng.Domain())
	}

	t0 := time.Now()
	if frozen, err := eng.ReapIdleOnce(t0); err != nil || len(frozen) != 0 {
		t.Fatalf("unexpected initial reap: %+v %v", frozen, err)
	}
	frozen, err := eng.ReapIdleOnce(t0.Add(30 * time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if len(frozen) != 1 || frozen[0].Project != "fast" {
		t.Fatalf("expected only fast (idle=20) frozen, got %+v", frozen)
	}

	res, err := eng.ThawProjectTarget("fast", "fast-redis-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.UnpausedContainers) != 1 || res.UnpausedContainers[0] != "cid-fast" {
		t.Fatalf("expected target cid-fast returned immediately, got %v", res.UnpausedContainers)
	}
	fastPausedCount := func() int {
		st, _ := eng.Status(t0.Add(31 * time.Second))
		for _, p := range st.Projects {
			if p.Project == "fast" {
				return p.PausedCount
			}
		}
		return -1
	}
	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		if fastPausedCount() == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := fastPausedCount(); got != 0 {
		t.Fatalf("expected sibling unpaused asynchronously, got pausedCount=%d", got)
	}
	if mapGuestDestHost("10.89.0.1") != "127.0.0.1" {
		t.Fatal("expected 10.89.0.1 mapped to 127.0.0.1")
	}
}
