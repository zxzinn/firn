package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	composeProjectLabel = "com.docker.compose.project"
	composeServiceLabel = "com.docker.compose.service"
	exemptLabel         = "firn.reaper.exempt"
	idleLabel           = "firn.reaper.idle"
	cpuActiveDeltaUsec  = uint64(50_000)
	netActiveDeltaBytes = uint64(256)
	reclaimChunkBytes   = uint64(64 * 1024 * 1024)
)

type DockerClient struct {
	socketPath string
	transport  *http.Transport
	client     *http.Client
}

func NewDockerClient(socketPath string) *DockerClient {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socketPath)
		},
	}
	return &DockerClient{
		socketPath: socketPath,
		transport:  transport,
		client: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
		},
	}
}

func (d *DockerClient) doJSON(method, path string, out any) (int, []byte, error) {
	req, err := http.NewRequest(method, "http://docker"+path, nil)
	if err != nil {
		return 0, nil, err
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	if out != nil && len(body) > 0 && resp.StatusCode < 300 {
		if err := json.Unmarshal(body, out); err != nil {
			return resp.StatusCode, body, err
		}
	}
	return resp.StatusCode, body, nil
}

type dockerContainerSummary struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	State  string            `json:"State"`
	Status string            `json:"Status"`
	Labels map[string]string `json:"Labels"`
}

type dockerPortBinding struct {
	HostIP   string `json:"HostIp"`
	HostPort string `json:"HostPort"`
}

type dockerNetworkEndpoint struct {
	IPAddress string `json:"IPAddress"`
}

type dockerContainerInspect struct {
	State struct {
		Pid    int  `json:"Pid"`
		Paused bool `json:"Paused"`
	} `json:"State"`
	NetworkSettings struct {
		Ports    map[string][]dockerPortBinding     `json:"Ports"`
		Networks map[string]dockerNetworkEndpoint `json:"Networks"`
	} `json:"NetworkSettings"`
}

func (d *DockerClient) ListContainers() ([]dockerContainerSummary, error) {
	var list []dockerContainerSummary
	status, body, err := d.doJSON(http.MethodGet, "/containers/json?all=1", &list)
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("docker list failed (%d): %s", status, strings.TrimSpace(string(body)))
	}
	return list, nil
}

func (d *DockerClient) InspectContainer(cid string) (*dockerContainerInspect, error) {
	var info dockerContainerInspect
	status, body, err := d.doJSON(http.MethodGet, "/containers/"+cid+"/json", &info)
	if err != nil {
		return nil, err
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("docker inspect %s failed (%d): %s", cid, status, strings.TrimSpace(string(body)))
	}
	return &info, nil
}

func (d *DockerClient) PauseContainer(cid string) error {
	status, body, err := d.doJSON(http.MethodPost, "/containers/"+cid+"/pause", nil)
	if err != nil {
		return err
	}
	if status != http.StatusNoContent && status != http.StatusNotModified && status != http.StatusConflict {
		return fmt.Errorf("docker pause %s failed (%d): %s", cid, status, strings.TrimSpace(string(body)))
	}
	return nil
}

func (d *DockerClient) UnpauseContainer(cid string) error {
	status, body, err := d.doJSON(http.MethodPost, "/containers/"+cid+"/unpause", nil)
	if err != nil {
		return err
	}
	if status != http.StatusNoContent && status != http.StatusNotModified && status != http.StatusConflict {
		return fmt.Errorf("docker unpause %s failed (%d): %s", cid, status, strings.TrimSpace(string(body)))
	}
	return nil
}

type DockerDFSummary struct {
	ImagesBytes      uint64 `json:"imagesBytes"`
	ContainersBytes  uint64 `json:"containersBytes"`
	VolumesBytes     uint64 `json:"volumesBytes"`
	BuildCacheBytes  uint64 `json:"buildCacheBytes"`
	ReclaimableBytes uint64 `json:"reclaimableBytes"`
}

func (d *DockerClient) SystemDF() (DockerDFSummary, error) {
	var raw struct {
		LayersSize int64 `json:"LayersSize"`
		Images     []struct {
			Size       int64 `json:"Size"`
			SharedSize int64 `json:"SharedSize"`
			Containers int   `json:"Containers"`
		} `json:"Images"`
		Containers []struct {
			SizeRw int64 `json:"SizeRw"`
		} `json:"Containers"`
		Volumes []struct {
			UsageData struct {
				Size     int64 `json:"Size"`
				RefCount int   `json:"RefCount"`
			} `json:"UsageData"`
		} `json:"Volumes"`
		BuildCache []struct {
			Size  int64 `json:"Size"`
			InUse bool  `json:"InUse"`
		} `json:"BuildCache"`
	}
	status, body, err := d.doJSON(http.MethodGet, "/system/df", &raw)
	if err != nil {
		return DockerDFSummary{}, err
	}
	if status != http.StatusOK {
		return DockerDFSummary{}, fmt.Errorf("docker system/df failed (%d): %s", status, strings.TrimSpace(string(body)))
	}
	var out DockerDFSummary
	var reclaimable int64
	if raw.LayersSize > 0 {
		out.ImagesBytes = uint64(raw.LayersSize)
	} else {
		for _, img := range raw.Images {
			if img.Size > 0 {
				out.ImagesBytes += uint64(img.Size)
			}
		}
	}
	for _, img := range raw.Images {
		if img.Containers <= 0 {
			unique := img.Size
			if img.SharedSize > 0 && img.SharedSize < unique {
				unique -= img.SharedSize
			}
			if unique > 0 {
				reclaimable += unique
			}
		}
	}
	for _, c := range raw.Containers {
		if c.SizeRw > 0 {
			out.ContainersBytes += uint64(c.SizeRw)
		}
	}
	for _, v := range raw.Volumes {
		if v.UsageData.Size > 0 {
			out.VolumesBytes += uint64(v.UsageData.Size)
			if v.UsageData.RefCount <= 0 {
				reclaimable += v.UsageData.Size
			}
		}
	}
	for _, bc := range raw.BuildCache {
		if bc.Size > 0 {
			out.BuildCacheBytes += uint64(bc.Size)
			if !bc.InUse {
				reclaimable += bc.Size
			}
		}
	}
	if reclaimable > 0 {
		out.ReclaimableBytes = uint64(reclaimable)
	}
	return out, nil
}

type DockerAPI interface {
	ListContainers() ([]dockerContainerSummary, error)
	InspectContainer(cid string) (*dockerContainerInspect, error)
	PauseContainer(cid string) error
	UnpauseContainer(cid string) error
	SystemDF() (DockerDFSummary, error)
}

type DockerEventStreamer interface {
	StreamContainerEvents(ctx context.Context, onEvent func()) error
}

func (d *DockerClient) StreamContainerEvents(ctx context.Context, onEvent func()) error {
	streamClient := &http.Client{Transport: d.transport}
	req, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		"http://docker/events?filters=%7B%22type%22%3A%5B%22container%22%5D%7D",
		nil,
	)
	if err != nil {
		return err
	}
	resp, err := streamClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker events returned status %d", resp.StatusCode)
	}
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 16*1024), 1024*1024)
	for scanner.Scan() {
		var evt struct {
			Action string `json:"Action"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &evt); err != nil {
			continue
		}
		switch evt.Action {
		case "start", "stop", "die", "pause", "unpause", "destroy", "rename":
			onEvent()
		}
	}
	return scanner.Err()
}

type VMMemoryInfo struct {
	TotalBytes     uint64 `json:"totalBytes"`
	FreeBytes      uint64 `json:"freeBytes"`
	AvailableBytes uint64 `json:"availableBytes"`
	CachedBytes    uint64 `json:"cachedBytes"`
	SwapTotalBytes uint64 `json:"swapTotalBytes"`
	SwapFreeBytes  uint64 `json:"swapFreeBytes"`
	SwapUsedBytes  uint64 `json:"swapUsedBytes"`
}

type ContainerStatus struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Service     string `json:"service"`
	PID         int    `json:"pid"`
	State       string `json:"state"`
	Paused      bool   `json:"paused"`
	Frozen      bool   `json:"frozen"`
	CgroupDir   string `json:"cgroupDir,omitempty"`
	MemoryBytes uint64 `json:"memoryBytes"`
	SwapBytes   uint64 `json:"swapBytes"`
	Established int    `json:"established"`
	IP          string `json:"ip,omitempty"`
}

type ProjectStatus struct {
	Project           string            `json:"project"`
	HasComposeProject bool              `json:"hasComposeProject"`
	Exempt            bool              `json:"exempt"`
	IdleLimitSeconds  int               `json:"idleLimitSeconds"`
	Containers        []ContainerStatus `json:"containers"`
	MemoryBytes       uint64            `json:"memoryBytes"`
	SwapBytes         uint64            `json:"swapBytes"`
	Established       int               `json:"established"`
	RunningCount      int               `json:"runningCount"`
	PausedCount       int               `json:"pausedCount"`
	FrozenCount       int               `json:"frozenCount"`
	IdleForSeconds    float64           `json:"idleForSeconds"`
}

type DiskUsageInfo struct {
	TotalBytes             uint64 `json:"totalBytes"`
	FreeBytes              uint64 `json:"freeBytes"`
	AvailableBytes         uint64 `json:"availableBytes"`
	UsedBytes              uint64 `json:"usedBytes"`
	SwapFileBytes          uint64 `json:"swapFileBytes"`
	ZramDiskBytes          uint64 `json:"zramDiskBytes"`
	ZramUsedBytes          uint64 `json:"zramUsedBytes"`
	DockerImagesBytes      uint64 `json:"dockerImagesBytes"`
	DockerContainersBytes  uint64 `json:"dockerContainersBytes"`
	DockerVolumesBytes     uint64 `json:"dockerVolumesBytes"`
	DockerBuildCacheBytes  uint64 `json:"dockerBuildCacheBytes"`
	DockerReclaimableBytes uint64 `json:"dockerReclaimableBytes"`
}

type GuestCapabilities struct {
	NestedKVM     bool `json:"nestedKvm"`
	GPUDRI        bool `json:"gpuDri"`
	FirnfsActive  bool `json:"firnfsActive"`
	FastVirtioNet bool `json:"fastVirtioNet"`
	K3sRunning    bool `json:"k3sRunning"`
}

type StatusResponse struct {
	IdleSeconds  int               `json:"idleSeconds"`
	Domain       string            `json:"domain"`
	VMMemory     VMMemoryInfo      `json:"vmMemory"`
	Projects     []ProjectStatus   `json:"projects"`
	Capabilities GuestCapabilities `json:"capabilities"`
}

type TopologyResponse struct {
	Version uint64        `json:"version"`
	Domain  string        `json:"domain"`
	Ports   []PortMapping `json:"ports"`
	Records []DNSRecord   `json:"records"`
}

type ReclaimContainerResult struct {
	Project        string `json:"project,omitempty"`
	Name           string `json:"name"`
	Supported      bool   `json:"supported"`
	BeforeBytes    uint64 `json:"beforeBytes"`
	AfterBytes     uint64 `json:"afterBytes"`
	ReclaimedBytes uint64 `json:"reclaimedBytes"`
	SwapBytes      uint64 `json:"swapBytes"`
}

type FreezeResult struct {
	Project             string                   `json:"project"`
	PausedContainers    []string                 `json:"pausedContainers"`
	Reclaim             []ReclaimContainerResult `json:"reclaim"`
	TotalReclaimedBytes uint64                   `json:"totalReclaimedBytes"`
	DurationMs          float64                  `json:"durationMs"`
}

type ThawResult struct {
	Project            string   `json:"project"`
	UnpausedContainers []string `json:"unpausedContainers"`
	DurationMs         float64  `json:"durationMs"`
}

type ReclaimResult struct {
	Project             string                   `json:"project,omitempty"`
	Reclaim             []ReclaimContainerResult `json:"reclaim"`
	TotalReclaimedBytes uint64                   `json:"totalReclaimedBytes"`
	DurationMs          float64                  `json:"durationMs"`
}

type activitySample struct {
	lastActive time.Time
	cpuUsec    uint64
	netBytes   uint64
}

type ReaperEngine struct {
	docker            DockerAPI
	procRoot          string
	cgroupRoot        string
	meminfoPath       string
	dropCachesPath    string
	compactMemoryPath string
	idleSeconds       int
	domain            string
	exemptProjects    map[string]bool
	extraPortsFn      func() []PortMapping
	extraDNSFn        func(domain string) []DNSRecord
	k3sRunningFn      func() bool
	capabilitiesFn    func() GuestCapabilities

	mu       sync.Mutex
	activity map[string]activitySample

	topoMu      sync.Mutex
	topoCond    *sync.Cond
	topoVersion uint64
	topoPorts   []PortMapping
	topoDNS     []DNSRecord
	topoUpdated time.Time
}

func NewReaperEngine(docker DockerAPI, idleSeconds int, domain string, exempt []string) *ReaperEngine {
	exemptSet := make(map[string]bool, len(exempt))
	for _, item := range exempt {
		if item != "" {
			exemptSet[item] = true
		}
	}
	eng := &ReaperEngine{
		docker:            docker,
		procRoot:          "/proc",
		cgroupRoot:        "/sys/fs/cgroup",
		meminfoPath:       "/proc/meminfo",
		dropCachesPath:    "/proc/sys/vm/drop_caches",
		compactMemoryPath: "/proc/sys/vm/compact_memory",
		idleSeconds:       idleSeconds,
		domain:            domain,
		exemptProjects:    exemptSet,
		activity:          make(map[string]activitySample),
		topoPorts:         []PortMapping{},
		topoDNS:           []DNSRecord{},
	}
	eng.topoCond = sync.NewCond(&eng.topoMu)
	return eng
}

func (e *ReaperEngine) Domain() string {
	e.mu.Lock()
	dom := e.domain
	e.mu.Unlock()
	return dom
}

func (e *ReaperEngine) ApplyConfig(idleSeconds int, domain string, exempt []string) {
	e.mu.Lock()
	if idleSeconds >= 0 {
		e.idleSeconds = idleSeconds
	}
	if domain != "" {
		e.domain = domain
	}
	if exempt != nil {
		exemptSet := make(map[string]bool, len(exempt))
		for _, item := range exempt {
			if item != "" {
				exemptSet[item] = true
			}
		}
		e.exemptProjects = exemptSet
	}
	e.mu.Unlock()
	_, _ = e.RefreshTopology(time.Now())
}

func readUint64File(path string) uint64 {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	val, err := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return 0
	}
	return val
}

func ParseMeminfo(path string) VMMemoryInfo {
	raw, err := os.ReadFile(path)
	if err != nil {
		return VMMemoryInfo{}
	}
	fields := make(map[string]uint64)
	for _, line := range strings.Split(string(raw), "\n") {
		k, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		parts := strings.Fields(rest)
		if len(parts) == 0 {
			continue
		}
		v, err := strconv.ParseUint(parts[0], 10, 64)
		if err != nil {
			continue
		}
		if len(parts) > 1 && strings.EqualFold(parts[1], "kB") {
			v *= 1024
		}
		fields[k] = v
	}
	swapUsed := uint64(0)
	if fields["SwapTotal"] > fields["SwapFree"] {
		swapUsed = fields["SwapTotal"] - fields["SwapFree"]
	}
	return VMMemoryInfo{
		TotalBytes:     fields["MemTotal"],
		FreeBytes:      fields["MemFree"],
		AvailableBytes: fields["MemAvailable"],
		CachedBytes:    fields["Cached"],
		SwapTotalBytes: fields["SwapTotal"],
		SwapFreeBytes:  fields["SwapFree"],
		SwapUsedBytes:  swapUsed,
	}
}

func parseCPUStat(path string) uint64 {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(raw), "\n") {
		parts := strings.Fields(line)
		if len(parts) == 2 && parts[0] == "usage_usec" {
			val, err := strconv.ParseUint(parts[1], 10, 64)
			if err == nil {
				return val
			}
		}
	}
	return 0
}

func readCgroupFrozen(cgDir string) bool {
	if raw, err := os.ReadFile(filepath.Join(cgDir, "cgroup.events")); err == nil {
		for _, line := range strings.Split(string(raw), "\n") {
			parts := strings.Fields(line)
			if len(parts) == 2 && parts[0] == "frozen" {
				return parts[1] == "1"
			}
		}
	}
	return readUint64File(filepath.Join(cgDir, "cgroup.freeze")) == 1
}

func DiscoverCgroupDir(pid int, cid, procRoot, cgroupRoot string) string {
	if pid > 0 {
		if raw, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "cgroup")); err == nil {
			for _, line := range strings.Split(string(raw), "\n") {
				parts := strings.SplitN(line, ":", 3)
				if len(parts) == 3 && parts[0] == "0" {
					rel := strings.TrimPrefix(strings.TrimSpace(parts[2]), "/")
					candidate := filepath.Join(cgroupRoot, rel)
					if _, err := os.Stat(candidate); err == nil {
						return candidate
					}
				}
			}
		}
	}
	for _, candidate := range []string{
		filepath.Join(cgroupRoot, "system.slice", "docker-"+cid+".scope"),
		filepath.Join(cgroupRoot, "docker", cid),
	} {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func countEstablishedSockets(pid int, procRoot string) int {
	if pid <= 0 {
		return 0
	}
	count := 0
	for _, file := range []string{"tcp", "tcp6"} {
		raw, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "net", file))
		if err != nil {
			continue
		}
		lines := strings.Split(string(raw), "\n")
		for idx, line := range lines {
			if idx == 0 {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 4 && fields[3] == "01" {
				count++
			}
		}
	}
	return count
}

func readNetDevBytes(pid int, procRoot string) uint64 {
	if pid <= 0 {
		return 0
	}
	raw, err := os.ReadFile(filepath.Join(procRoot, strconv.Itoa(pid), "net", "dev"))
	if err != nil {
		return 0
	}
	var total uint64
	for idx, line := range strings.Split(string(raw), "\n") {
		if idx < 2 {
			continue
		}
		iface, data, ok := strings.Cut(line, ":")
		if !ok || strings.TrimSpace(iface) == "lo" {
			continue
		}
		cols := strings.Fields(data)
		if len(cols) >= 9 {
			rx, _ := strconv.ParseUint(cols[0], 10, 64)
			tx, _ := strconv.ParseUint(cols[8], 10, 64)
			total += rx + tx
		}
	}
	return total
}

func writeSysfsControl(path string, payload []byte) error {
	// Open directly via syscall without O_NONBLOCK so kernfs/cgroupfs EAGAIN
	// returns to the caller instead of blocking Go's netpoller waitWrite forever.
	fd, err := syscall.Open(path, syscall.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	for {
		_, werr := syscall.Write(fd, payload)
		if errors.Is(werr, syscall.EINTR) {
			continue
		}
		return werr
	}
}

func ReclaimCgroupMemory(cgDir string) ReclaimContainerResult {
	if cgDir == "" {
		return ReclaimContainerResult{}
	}
	reclaimPath := filepath.Join(cgDir, "memory.reclaim")
	currentPath := filepath.Join(cgDir, "memory.current")
	swapPath := filepath.Join(cgDir, "memory.swap.current")
	before := readUint64File(currentPath)
	if _, err := os.Stat(reclaimPath); err != nil {
		return ReclaimContainerResult{
			Supported:   false,
			BeforeBytes: before,
			AfterBytes:  before,
			SwapBytes:   readUint64File(swapPath),
		}
	}
	supported := true
	prev := before
	for range 8 {
		if prev <= 4*1024*1024 {
			break
		}
		target := min(prev-4*1024*1024, reclaimChunkBytes)
		if target < 1024*1024 {
			target = 1024 * 1024
		}
		if err := writeSysfsControl(reclaimPath, []byte(fmt.Sprintf("%d\n", target))); err != nil {
			if errors.Is(err, syscall.EOPNOTSUPP) || errors.Is(err, syscall.ENOENT) {
				supported = false
				break
			}
			cur := readUint64File(currentPath)
			prev = cur
			if errors.Is(err, syscall.EAGAIN) {
				// Partial reclaim succeeded up to cur; no further reclaimable cold pages remain.
				break
			}
			break
		}
		cur := readUint64File(currentPath)
		if prev <= cur || (prev-cur) < 1024*1024 {
			prev = cur
			break
		}
		prev = cur
	}
	after := readUint64File(currentPath)
	reclaimed := uint64(0)
	if before > after {
		reclaimed = before - after
	}
	return ReclaimContainerResult{
		Supported:      supported,
		BeforeBytes:    before,
		AfterBytes:     after,
		ReclaimedBytes: reclaimed,
		SwapBytes:      readUint64File(swapPath),
	}
}

func (e *ReaperEngine) collectLocked(now time.Time) (map[string]*ProjectStatus, []PortMapping, []DNSRecord, error) {
	items, err := e.docker.ListContainers()
	if err != nil {
		return nil, nil, nil, err
	}
	projects := make(map[string]*ProjectStatus)
	liveIDs := make(map[string]bool, len(items))
	var ports []PortMapping
	var dnsRecords []DNSRecord
	serviceGroups := make(map[string][]string)
	customIdleSet := make(map[string]bool)

	for _, item := range items {
		liveIDs[item.ID] = true
		project := item.Labels[composeProjectLabel]
		groupKey := project
		if groupKey == "" {
			groupKey = "(standalone)"
		}
		name := item.ID[:min(12, len(item.ID))]
		if len(item.Names) > 0 {
			name = strings.TrimPrefix(item.Names[0], "/")
		}
		service := item.Labels[composeServiceLabel]
		if service == "" {
			service = name
		}
		paused := item.State == "paused" || strings.Contains(item.Status, "(Paused)")
		var pid int
		var ip string
		var inspected *dockerContainerInspect
		if item.State == "running" || item.State == "paused" {
			inspected, err = e.docker.InspectContainer(item.ID)
			if err == nil && inspected != nil {
				pid = inspected.State.Pid
				paused = inspected.State.Paused
				for _, netInfo := range inspected.NetworkSettings.Networks {
					if netInfo.IPAddress != "" {
						ip = netInfo.IPAddress
						break
					}
				}
			}
		}

		var cgDir string
		var memBytes, swapBytes, cpuUsec, netBytes uint64
		var frozen bool
		var established int
		if item.State == "running" || item.State == "paused" {
			cgDir = DiscoverCgroupDir(pid, item.ID, e.procRoot, e.cgroupRoot)
			if cgDir != "" {
				memBytes = readUint64File(filepath.Join(cgDir, "memory.current"))
				swapBytes = readUint64File(filepath.Join(cgDir, "memory.swap.current"))
				cpuUsec = parseCPUStat(filepath.Join(cgDir, "cpu.stat"))
				frozen = readCgroupFrozen(cgDir)
			} else {
				frozen = paused
			}
			if item.State == "running" && !paused {
				established = countEstablishedSockets(pid, e.procRoot)
				netBytes = readNetDevBytes(pid, e.procRoot)
			}
		}

		prev, seen := e.activity[item.ID]
		lastActive := now
		if seen {
			activeNow := item.State == "running" && !paused && (established > 0 ||
				(netBytes > prev.netBytes && netBytes-prev.netBytes > netActiveDeltaBytes) ||
				(cpuUsec > prev.cpuUsec && cpuUsec-prev.cpuUsec > cpuActiveDeltaUsec))
			if !activeNow {
				lastActive = prev.lastActive
			}
		}
		e.activity[item.ID] = activitySample{lastActive: lastActive, cpuUsec: cpuUsec, netBytes: netBytes}

		group, exists := projects[groupKey]
		if !exists {
			group = &ProjectStatus{
				Project:           groupKey,
				HasComposeProject: project != "",
				Exempt:            project == "" || e.exemptProjects[project],
				IdleLimitSeconds:  e.idleSeconds,
			}
			projects[groupKey] = group
		}
		if strings.EqualFold(item.Labels[exemptLabel], "true") {
			group.Exempt = true
		}
		if rawIdle, ok := item.Labels[idleLabel]; ok {
			if parsedIdle, perr := strconv.Atoi(strings.TrimSpace(rawIdle)); perr == nil {
				if parsedIdle == 0 {
					group.Exempt = true
					group.IdleLimitSeconds = 0
					customIdleSet[groupKey] = true
				} else if parsedIdle > 0 && (!customIdleSet[groupKey] || parsedIdle < group.IdleLimitSeconds) {
					group.IdleLimitSeconds = parsedIdle
					customIdleSet[groupKey] = true
				}
			}
		}
		group.MemoryBytes += memBytes
		group.SwapBytes += swapBytes
		group.Established += established
		if item.State == "running" && !paused {
			group.RunningCount++
		}
		if paused {
			group.PausedCount++
		}
		if frozen {
			group.FrozenCount++
		}
		idleSec := now.Sub(lastActive).Seconds()
		if len(group.Containers) == 0 || idleSec < group.IdleForSeconds {
			group.IdleForSeconds = max(0, idleSec)
		}
		group.Containers = append(group.Containers, ContainerStatus{
			ID:          item.ID,
			Name:        name,
			Service:     service,
			PID:         pid,
			State:       item.State,
			Paused:      paused,
			Frozen:      frozen,
			CgroupDir:   cgDir,
			MemoryBytes: memBytes,
			SwapBytes:   swapBytes,
			Established: established,
			IP:          ip,
		})

		if inspected != nil && (item.State == "running" || item.State == "paused") {
			containerPorts := extractContainerPorts(inspected, project, service, name, ip, paused)
			ports = append(ports, containerPorts...)
			extraLabel := item.Labels[machineNameLabel]
			names, primaryPort := buildContainerDNSNames(name, service, project, e.domain, containerPorts, extraLabel)
			if project != "" {
				serviceGroups[project] = append(serviceGroups[project], name)
			}
			if len(names) > 0 {
				dnsRecords = append(dnsRecords, DNSRecord{
					Names:         names,
					ContainerName: name,
					Project:       project,
					Service:       service,
					IP:            ip,
					HTTPPort:      primaryPort,
					Paused:        paused,
				})
			}
		}
	}

	for cid := range e.activity {
		if !liveIDs[cid] {
			delete(e.activity, cid)
		}
	}

	if e.extraPortsFn != nil {
		ports = append(ports, e.extraPortsFn()...)
	}
	if e.extraDNSFn != nil {
		dnsRecords = append(dnsRecords, e.extraDNSFn(e.domain)...)
	}
	sort.Slice(ports, func(i, j int) bool { return ports[i].HostPort < ports[j].HostPort })
	return projects, ports, dnsRecords, nil
}

func (e *ReaperEngine) Status(now time.Time) (StatusResponse, error) {
	e.mu.Lock()
	projectsMap, _, _, err := e.collectLocked(now)
	capsFn := e.capabilitiesFn
	domain := e.domain
	idleSec := e.idleSeconds
	e.mu.Unlock()
	if err != nil {
		return StatusResponse{}, err
	}
	list := make([]ProjectStatus, 0, len(projectsMap))
	for _, item := range projectsMap {
		item.IdleForSeconds = float64(int(item.IdleForSeconds*10)) / 10
		list = append(list, *item)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Project < list[j].Project })
	var caps GuestCapabilities
	if capsFn != nil {
		caps = capsFn()
	}
	return StatusResponse{
		IdleSeconds:  idleSec,
		Domain:       domain,
		VMMemory:     ParseMeminfo(e.meminfoPath),
		Projects:     list,
		Capabilities: caps,
	}, nil
}

func (e *ReaperEngine) FreezeProject(project string, reclaim, dropCaches bool) (FreezeResult, error) {
	started := time.Now()
	res, err := func() (FreezeResult, error) {
		e.mu.Lock()
		defer e.mu.Unlock()
		projectsMap, _, _, err := e.collectLocked(started)
		if err != nil {
			return FreezeResult{}, err
		}
		group, ok := projectsMap[project]
		if !ok {
			return FreezeResult{}, fmt.Errorf("unknown project: %s", project)
		}
		out := FreezeResult{Project: project}
		for _, c := range group.Containers {
			if c.State == "running" && !c.Paused {
				if err := e.docker.PauseContainer(c.ID); err != nil {
					return FreezeResult{}, err
				}
				out.PausedContainers = append(out.PausedContainers, c.ID)
			}
		}
		if reclaim {
			for _, c := range group.Containers {
				if c.CgroupDir != "" && (c.State == "running" || c.State == "paused") {
					rec := ReclaimCgroupMemory(c.CgroupDir)
					rec.Name = c.Name
					rec.Project = project
					out.Reclaim = append(out.Reclaim, rec)
					out.TotalReclaimedBytes += rec.ReclaimedBytes
				}
			}
			if dropCaches {
				_ = writeSysfsControl(e.dropCachesPath, []byte("3\n"))
				if e.compactMemoryPath != "" {
					_ = writeSysfsControl(e.compactMemoryPath, []byte("1\n"))
				}
			}
		}
		out.DurationMs = float64(int(time.Since(started).Seconds()*100_000)) / 100
		return out, nil
	}()
	if err != nil {
		return FreezeResult{}, err
	}
	_, _ = e.RefreshTopology(time.Now())
	return res, nil
}

func (e *ReaperEngine) ThawProject(project string) (ThawResult, error) {
	return e.ThawProjectTarget(project, "")
}

func (e *ReaperEngine) ThawProjectTarget(project, target string) (ThawResult, error) {
	started := time.Now()
	e.mu.Lock()
	projectsMap, _, _, err := e.collectLocked(started)
	if err != nil {
		e.mu.Unlock()
		return ThawResult{}, err
	}
	group, ok := projectsMap[project]
	if !ok {
		e.mu.Unlock()
		return ThawResult{}, fmt.Errorf("unknown project: %s", project)
	}

	var targetID string
	var otherPaused []string
	for _, c := range group.Containers {
		if !c.Paused {
			continue
		}
		if target != "" && (c.Name == target || c.Service == target || c.ID == target) {
			targetID = c.ID
		} else {
			otherPaused = append(otherPaused, c.ID)
		}
	}
	e.mu.Unlock()

	waitUnpaused := func(cid string, interval time.Duration) {
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			info, ierr := e.docker.InspectContainer(cid)
			if ierr == nil && info != nil && !info.State.Paused {
				return
			}
			time.Sleep(interval)
		}
	}

	unpauseBatch := func(ids []string, interval time.Duration) {
		var wg sync.WaitGroup
		for _, cid := range ids {
			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				_ = e.docker.UnpauseContainer(id)
				waitUnpaused(id, interval)
			}(cid)
		}
		wg.Wait()
	}

	out := ThawResult{Project: project}
	if target != "" && targetID != "" {
		if err := e.docker.UnpauseContainer(targetID); err != nil {
			return ThawResult{}, err
		}
		waitUnpaused(targetID, 2*time.Millisecond)
		now := time.Now()
		e.mu.Lock()
		sample := e.activity[targetID]
		sample.lastActive = now
		e.activity[targetID] = sample
		e.mu.Unlock()
		out.UnpausedContainers = append(out.UnpausedContainers, targetID)
		out.DurationMs = float64(int(time.Since(started).Seconds()*100_000)) / 100
		go func(rest []string) {
			if len(rest) > 0 {
				unpauseBatch(rest, 5*time.Millisecond)
				t := time.Now()
				e.mu.Lock()
				for _, id := range rest {
					s := e.activity[id]
					s.lastActive = t
					e.activity[id] = s
				}
				e.mu.Unlock()
			}
			_, _ = e.RefreshTopology(time.Now())
		}(otherPaused)
		return out, nil
	}

	if len(otherPaused) > 0 {
		var wg sync.WaitGroup
		var errsMu sync.Mutex
		var firstErr error
		for _, cid := range otherPaused {
			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				if uerr := e.docker.UnpauseContainer(id); uerr != nil {
					errsMu.Lock()
					if firstErr == nil {
						firstErr = uerr
					}
					errsMu.Unlock()
					return
				}
				waitUnpaused(id, 4*time.Millisecond)
			}(cid)
		}
		wg.Wait()
		if firstErr != nil {
			return ThawResult{}, firstErr
		}
		now := time.Now()
		e.mu.Lock()
		for _, cid := range otherPaused {
			s := e.activity[cid]
			s.lastActive = now
			e.activity[cid] = s
		}
		e.mu.Unlock()
		out.UnpausedContainers = append(out.UnpausedContainers, otherPaused...)
	}
	out.DurationMs = float64(int(time.Since(started).Seconds()*100_000)) / 100
	go e.RefreshTopology(time.Now())
	return out, nil
}

func (e *ReaperEngine) Reclaim(project string, dropCaches bool) (ReclaimResult, error) {
	started := time.Now()
	e.mu.Lock()
	defer e.mu.Unlock()
	projectsMap, _, _, err := e.collectLocked(started)
	if err != nil {
		return ReclaimResult{}, err
	}
	var targets []*ProjectStatus
	if project != "" {
		group, ok := projectsMap[project]
		if !ok {
			return ReclaimResult{}, fmt.Errorf("unknown project: %s", project)
		}
		targets = []*ProjectStatus{group}
	} else {
		for _, group := range projectsMap {
			if !group.Exempt && group.PausedCount > 0 {
				targets = append(targets, group)
			}
		}
	}
	res := ReclaimResult{Project: project}
	for _, group := range targets {
		for _, c := range group.Containers {
			if c.CgroupDir != "" && (c.State == "running" || c.State == "paused") {
				rec := ReclaimCgroupMemory(c.CgroupDir)
				rec.Project = group.Project
				rec.Name = c.Name
				res.Reclaim = append(res.Reclaim, rec)
				res.TotalReclaimedBytes += rec.ReclaimedBytes
			}
		}
	}
	if dropCaches {
		_ = writeSysfsControl(e.dropCachesPath, []byte("3\n"))
		if e.compactMemoryPath != "" {
			_ = writeSysfsControl(e.compactMemoryPath, []byte("1\n"))
		}
	}
	res.DurationMs = float64(int(time.Since(started).Seconds()*100_000)) / 100
	return res, nil
}

func (e *ReaperEngine) ReapIdleOnce(now time.Time) ([]FreezeResult, error) {
	status, err := e.Status(now)
	if err != nil {
		return nil, err
	}
	var results []FreezeResult
	for _, group := range status.Projects {
		if group.Exempt || !group.HasComposeProject || group.RunningCount == 0 {
			continue
		}
		limit := group.IdleLimitSeconds
		if limit <= 0 {
			limit = status.IdleSeconds
		}
		if limit > 0 && group.IdleForSeconds >= float64(limit) {
			frozen, err := e.FreezeProject(group.Project, true, true)
			if err != nil {
				return results, err
			}
			results = append(results, frozen)
		}
	}
	return results, nil
}

func (e *ReaperEngine) DiskUsage() DiskUsageInfo {
	var out DiskUsageInfo
	var st unix.Statfs_t
	target := "/var/lib/firn"
	if _, err := os.Stat(target); err != nil {
		target = "/"
	}
	if err := unix.Statfs(target, &st); err == nil && st.Bsize > 0 {
		bsize := uint64(st.Bsize)
		out.TotalBytes = st.Blocks * bsize
		out.FreeBytes = st.Bfree * bsize
		out.AvailableBytes = st.Bavail * bsize
		if out.TotalBytes > out.FreeBytes {
			out.UsedBytes = out.TotalBytes - out.FreeBytes
		}
	}
	if fi, err := os.Stat("/var/lib/firn/swapfile"); err == nil {
		out.SwapFileBytes = uint64(fi.Size())
	}
	if raw, err := os.ReadFile("/sys/block/zram0/disksize"); err == nil {
		out.ZramDiskBytes, _ = strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	}
	if raw, err := os.ReadFile("/sys/block/zram0/mm_stat"); err == nil {
		cols := strings.Fields(string(raw))
		if len(cols) >= 3 {
			out.ZramUsedBytes, _ = strconv.ParseUint(cols[2], 10, 64)
		}
	}
	if e.docker != nil {
		if df, err := e.docker.SystemDF(); err == nil {
			out.DockerImagesBytes = df.ImagesBytes
			out.DockerContainersBytes = df.ContainersBytes
			out.DockerVolumesBytes = df.VolumesBytes
			out.DockerBuildCacheBytes = df.BuildCacheBytes
			out.DockerReclaimableBytes = df.ReclaimableBytes
		}
	}
	return out
}

func (e *ReaperEngine) TrimDisk() (string, error) {
	out, err := exec.Command("fstrim", "-v", "/var/lib/firn").CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func (e *ReaperEngine) PruneDisk(all bool) (map[string]any, error) {
	var summaries []string
	builderArgs := []string{"builder", "prune", "-f"}
	imageArgs := []string{"image", "prune", "-f"}
	if all {
		builderArgs = append(builderArgs, "-a")
		imageArgs = append(imageArgs, "-a")
	}
	if out, err := exec.Command("docker", builderArgs...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("docker builder prune failed: %w (%s)", err, strings.TrimSpace(string(out)))
	} else if s := strings.TrimSpace(string(out)); s != "" {
		summaries = append(summaries, s)
	}
	if out, err := exec.Command("docker", imageArgs...).CombinedOutput(); err != nil {
		return nil, fmt.Errorf("docker image prune failed: %w (%s)", err, strings.TrimSpace(string(out)))
	} else if s := strings.TrimSpace(string(out)); s != "" {
		summaries = append(summaries, s)
	}
	if all {
		if out, err := exec.Command("docker", "container", "prune", "-f").CombinedOutput(); err != nil {
			return nil, fmt.Errorf("docker container prune failed: %w (%s)", err, strings.TrimSpace(string(out)))
		} else if s := strings.TrimSpace(string(out)); s != "" {
			summaries = append(summaries, s)
		}
	}
	if trimOut, err := e.TrimDisk(); err == nil && trimOut != "" {
		summaries = append(summaries, trimOut)
	}
	_, _ = e.RefreshTopology(time.Now())
	return map[string]any{
		"ok":      true,
		"all":     all,
		"summary": strings.Join(summaries, "\n"),
		"disk":    e.DiskUsage(),
	}, nil
}

func clonePorts(src []PortMapping) []PortMapping {
	out := make([]PortMapping, len(src))
	copy(out, src)
	return out
}

func cloneDNS(src []DNSRecord) []DNSRecord {
	out := make([]DNSRecord, len(src))
	copy(out, src)
	return out
}

func (e *ReaperEngine) updateTopologySnapshot(ports []PortMapping, dnsRecords []DNSRecord, now time.Time) TopologyResponse {
	cleanPorts := clonePorts(ports)
	cleanDNS := cloneDNS(dnsRecords)
	e.topoMu.Lock()
	defer e.topoMu.Unlock()
	if e.topoVersion == 0 || !reflect.DeepEqual(e.topoPorts, cleanPorts) || !reflect.DeepEqual(e.topoDNS, cleanDNS) {
		e.topoVersion++
		e.topoPorts = cleanPorts
		e.topoDNS = cleanDNS
		e.topoCond.Broadcast()
	}
	e.topoUpdated = now
	return TopologyResponse{
		Version: e.topoVersion,
		Domain:  e.domain,
		Ports:   clonePorts(e.topoPorts),
		Records: cloneDNS(e.topoDNS),
	}
}

func (e *ReaperEngine) RefreshTopology(now time.Time) (TopologyResponse, error) {
	e.mu.Lock()
	_, ports, dnsRecords, err := e.collectLocked(now)
	e.mu.Unlock()
	if err != nil {
		return TopologyResponse{}, err
	}
	return e.updateTopologySnapshot(ports, dnsRecords, now), nil
}

func (e *ReaperEngine) CachedPortsAndDNS(now time.Time) ([]PortMapping, []DNSRecord, error) {
	e.topoMu.Lock()
	if e.topoVersion > 0 && now.Sub(e.topoUpdated) < 5*time.Second {
		ports := clonePorts(e.topoPorts)
		dns := cloneDNS(e.topoDNS)
		e.topoMu.Unlock()
		return ports, dns, nil
	}
	e.topoMu.Unlock()
	resp, err := e.RefreshTopology(now)
	return resp.Ports, resp.Records, err
}

func (e *ReaperEngine) WaitTopology(ctx context.Context, since uint64, wait time.Duration) (TopologyResponse, error) {
	e.topoMu.Lock()
	version := e.topoVersion
	e.topoMu.Unlock()
	if version == 0 {
		return e.RefreshTopology(time.Now())
	}
	if since == 0 || version > since || wait <= 0 {
		if since == 0 {
			return e.RefreshTopology(time.Now())
		}
		e.topoMu.Lock()
		resp := TopologyResponse{
			Version: e.topoVersion,
			Domain:  e.domain,
			Ports:   clonePorts(e.topoPorts),
			Records: cloneDNS(e.topoDNS),
		}
		e.topoMu.Unlock()
		return resp, nil
	}

	done := false
	timer := time.AfterFunc(wait, func() {
		e.topoMu.Lock()
		done = true
		e.topoCond.Broadcast()
		e.topoMu.Unlock()
	})
	defer timer.Stop()

	stopCtx := context.AfterFunc(ctx, func() {
		e.topoMu.Lock()
		done = true
		e.topoCond.Broadcast()
		e.topoMu.Unlock()
	})
	defer stopCtx()

	e.topoMu.Lock()
	for e.topoVersion <= since && !done {
		e.topoCond.Wait()
	}
	resp := TopologyResponse{
		Version: e.topoVersion,
		Domain:  e.domain,
		Ports:   clonePorts(e.topoPorts),
		Records: cloneDNS(e.topoDNS),
	}
	e.topoMu.Unlock()
	return resp, ctx.Err()
}

func (e *ReaperEngine) WatchDockerEvents(ctx context.Context) {
	streamer, ok := e.docker.(DockerEventStreamer)
	if !ok {
		return
	}
	_, _ = e.RefreshTopology(time.Now())

	trigger := make(chan struct{}, 1)
	go func() {
		safety := time.NewTicker(30 * time.Second)
		k8sTick := time.NewTicker(2 * time.Second)
		defer safety.Stop()
		defer k8sTick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-trigger:
				time.Sleep(40 * time.Millisecond)
				select {
				case <-trigger:
				default:
				}
				_, _ = e.RefreshTopology(time.Now())
			case <-k8sTick.C:
				if e.k3sRunningFn != nil && e.k3sRunningFn() {
					_, _ = e.RefreshTopology(time.Now())
				}
			case <-safety.C:
				_, _ = e.RefreshTopology(time.Now())
			}
		}
	}()

	for {
		if ctx.Err() != nil {
			return
		}
		err := streamer.StreamContainerEvents(ctx, func() {
			select {
			case trigger <- struct{}{}:
			default:
			}
		})
		if err != nil && ctx.Err() == nil {
			time.Sleep(500 * time.Millisecond)
			_, _ = e.RefreshTopology(time.Now())
		}
	}
}

func (e *ReaperEngine) PortsAndDNS(now time.Time) ([]PortMapping, []DNSRecord, error) {
	return e.CachedPortsAndDNS(now)
}

func (e *ReaperEngine) DropPageCaches() error {
	if err := writeSysfsControl(e.dropCachesPath, []byte("3\n")); err != nil {
		return err
	}
	if e.compactMemoryPath != "" {
		_ = writeSysfsControl(e.compactMemoryPath, []byte("1\n"))
	}
	return nil
}
