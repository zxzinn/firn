package main

import (
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	defaultDockerVolumesRoot = "/var/lib/firn/docker/volumes"
	defaultSnapshotsRoot     = "/var/lib/firn/snapshots"
)

var safeVolumeNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$`)

func isValidVolumeOrSnapshotName(name string) bool {
	if !safeVolumeNameRe.MatchString(name) || strings.Contains(name, "..") {
		return false
	}
	return true
}

type VolumeSnapshotInfo struct {
	Name       string  `json:"name"`
	Volume     string  `json:"volume"`
	CreatedAt  string  `json:"createdAt"`
	Files      int64   `json:"files"`
	Bytes      uint64  `json:"bytes"`
	CloneMode  string  `json:"cloneMode"`
	DurationMs float64 `json:"durationMs"`
	Quiesced   bool    `json:"quiesced"`
}

type VolumeCloneResult struct {
	Source     string  `json:"source"`
	SourceType string  `json:"sourceType"`
	Target     string  `json:"target"`
	Files      int64   `json:"files"`
	Bytes      uint64  `json:"bytes"`
	CloneMode  string  `json:"cloneMode"`
	DurationMs float64 `json:"durationMs"`
	Quiesced   bool    `json:"quiesced"`
}

type VolumeManager struct {
	engine        *ReaperEngine
	volumesRoot   string
	snapshotsRoot string
	useDockerCLI  bool
	mu            sync.Mutex
}

func NewVolumeManager(engine *ReaperEngine, volumesRoot, snapshotsRoot string, useDockerCLI bool) *VolumeManager {
	if volumesRoot == "" {
		volumesRoot = defaultDockerVolumesRoot
	}
	if snapshotsRoot == "" {
		snapshotsRoot = defaultSnapshotsRoot
	}
	return &VolumeManager{
		engine:        engine,
		volumesRoot:   volumesRoot,
		snapshotsRoot: snapshotsRoot,
		useDockerCLI:  useDockerCLI,
	}
}

func (vm *VolumeManager) ListSnapshots() ([]VolumeSnapshotInfo, error) {
	entries, err := os.ReadDir(vm.snapshotsRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return []VolumeSnapshotInfo{}, nil
		}
		return nil, err
	}
	out := make([]VolumeSnapshotInfo, 0, len(entries))
	for _, ent := range entries {
		if !ent.IsDir() || strings.HasPrefix(ent.Name(), ".") {
			continue
		}
		metaPath := filepath.Join(vm.snapshotsRoot, ent.Name(), "meta.json")
		raw, rerr := os.ReadFile(metaPath)
		if rerr != nil {
			continue
		}
		var info VolumeSnapshotInfo
		if json.Unmarshal(raw, &info) == nil {
			if info.Name == "" {
				info.Name = ent.Name()
			}
			out = append(out, info)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt > out[j].CreatedAt
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

func (vm *VolumeManager) TotalSnapshotsBytes() uint64 {
	snaps, err := vm.ListSnapshots()
	if err != nil {
		return 0
	}
	var total uint64
	for _, s := range snaps {
		total += s.Bytes
	}
	return total
}

func (vm *VolumeManager) quiesceVolumeContainers(volumes ...string) func() {
	if vm.engine == nil || vm.engine.docker == nil {
		return func() {}
	}
	volSet := make(map[string]bool)
	for _, v := range volumes {
		if v != "" {
			volSet[v] = true
		}
	}
	if len(volSet) == 0 {
		return func() {}
	}
	items, err := vm.engine.docker.ListContainers()
	if err != nil {
		return func() {}
	}
	var pausedIDs []string
	for _, item := range items {
		if item.State != "running" {
			continue
		}
		ins, ierr := vm.engine.docker.InspectContainer(item.ID)
		if ierr != nil || ins == nil || ins.State.Paused {
			continue
		}
		matched := false
		for _, m := range ins.Mounts {
			if m.Name != "" && volSet[m.Name] {
				matched = true
				break
			}
		}
		if matched {
			if vm.engine.docker.PauseContainer(item.ID) == nil {
				pausedIDs = append(pausedIDs, item.ID)
			}
		}
	}
	if len(pausedIDs) > 0 {
		syncFilesystem()
	}
	return func() {
		for _, cid := range pausedIDs {
			_ = vm.engine.docker.UnpauseContainer(cid)
			vm.engine.InvalidateInspectCache(cid)
		}
	}
}

func (vm *VolumeManager) CreateSnapshot(volume, snapshot string, quiesce bool) (VolumeSnapshotInfo, error) {
	started := time.Now()
	if !isValidVolumeOrSnapshotName(volume) {
		return VolumeSnapshotInfo{}, fmt.Errorf("invalid volume name %q", volume)
	}
	if snapshot == "" {
		snapshot = fmt.Sprintf("%s-%s", volume, time.Now().Format("20060102-150405"))
	}
	if !isValidVolumeOrSnapshotName(snapshot) {
		return VolumeSnapshotInfo{}, fmt.Errorf("invalid snapshot name %q", snapshot)
	}

	vm.mu.Lock()
	defer vm.mu.Unlock()

	srcData := filepath.Join(vm.volumesRoot, volume, "_data")
	st, err := os.Stat(srcData)
	if err != nil || !st.IsDir() {
		return VolumeSnapshotInfo{}, fmt.Errorf("volume %q not found (%s)", volume, srcData)
	}

	if err := os.MkdirAll(vm.snapshotsRoot, 0o755); err != nil {
		return VolumeSnapshotInfo{}, err
	}
	snapDir := filepath.Join(vm.snapshotsRoot, snapshot)
	if _, err := os.Stat(snapDir); err == nil {
		return VolumeSnapshotInfo{}, fmt.Errorf("snapshot %q already exists", snapshot)
	}

	if quiesce {
		resume := vm.quiesceVolumeContainers(volume)
		defer resume()
	}

	tmpDir := filepath.Join(vm.snapshotsRoot, fmt.Sprintf(".tmp-%s-%d", snapshot, time.Now().UnixNano()))
	tmpData := filepath.Join(tmpDir, "data")
	if err := os.MkdirAll(tmpData, 0o755); err != nil {
		return VolumeSnapshotInfo{}, err
	}
	cleanupTmp := true
	defer func() {
		if cleanupTmp {
			_ = os.RemoveAll(tmpDir)
		}
	}()

	files, totalBytes, modeUsed, err := copyTreeFast(srcData, tmpData)
	if err != nil {
		return VolumeSnapshotInfo{}, err
	}
	syncFilesystem()

	info := VolumeSnapshotInfo{
		Name:       snapshot,
		Volume:     volume,
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
		Files:      files,
		Bytes:      totalBytes,
		CloneMode:  modeUsed,
		DurationMs: float64(int(time.Since(started).Seconds()*100_000)) / 100,
		Quiesced:   quiesce,
	}
	metaBytes, err := json.MarshalIndent(info, "", "  ")
	if err != nil {
		return VolumeSnapshotInfo{}, err
	}
	if err := os.WriteFile(filepath.Join(tmpDir, "meta.json"), metaBytes, 0o644); err != nil {
		return VolumeSnapshotInfo{}, err
	}
	if err := os.Rename(tmpDir, snapDir); err != nil {
		return VolumeSnapshotInfo{}, err
	}
	cleanupTmp = false
	return info, nil
}

func (vm *VolumeManager) CloneVolume(source, targetVolume string, fromSnapshotOnly, quiesce, overwrite bool) (VolumeCloneResult, error) {
	started := time.Now()
	if !isValidVolumeOrSnapshotName(source) {
		return VolumeCloneResult{}, fmt.Errorf("invalid source name %q", source)
	}
	if !isValidVolumeOrSnapshotName(targetVolume) {
		return VolumeCloneResult{}, fmt.Errorf("invalid target volume name %q", targetVolume)
	}

	vm.mu.Lock()
	defer vm.mu.Unlock()

	var srcData, sourceType string
	snapData := filepath.Join(vm.snapshotsRoot, source, "data")
	volData := filepath.Join(vm.volumesRoot, source, "_data")
	if st, err := os.Stat(snapData); err == nil && st.IsDir() {
		srcData = snapData
		sourceType = "snapshot"
	} else if !fromSnapshotOnly {
		if st, err := os.Stat(volData); err == nil && st.IsDir() {
			if source == targetVolume {
				return VolumeCloneResult{}, fmt.Errorf("target volume %q must differ from source volume", targetVolume)
			}
			srcData = volData
			sourceType = "volume"
		}
	}
	if srcData == "" {
		return VolumeCloneResult{}, fmt.Errorf("source %q not found as snapshot or volume", source)
	}

	dstData := filepath.Join(vm.volumesRoot, targetVolume, "_data")
	if st, err := os.Stat(dstData); err == nil && st.IsDir() {
		entries, _ := os.ReadDir(dstData)
		if len(entries) > 0 {
			if !overwrite {
				return VolumeCloneResult{}, fmt.Errorf("target volume %q already exists and is not empty (pass --overwrite to replace)", targetVolume)
			}
			for _, ent := range entries {
				if rerr := os.RemoveAll(filepath.Join(dstData, ent.Name())); rerr != nil {
					return VolumeCloneResult{}, rerr
				}
			}
		}
	} else {
		if vm.useDockerCLI {
			if out, cerr := exec.Command("docker", "volume", "create", targetVolume).CombinedOutput(); cerr != nil {
				return VolumeCloneResult{}, fmt.Errorf("docker volume create %s failed: %w (%s)", targetVolume, cerr, strings.TrimSpace(string(out)))
			}
		}
		if err := os.MkdirAll(dstData, 0o755); err != nil {
			return VolumeCloneResult{}, err
		}
	}

	if quiesce {
		var quiesceList []string
		if sourceType == "volume" {
			quiesceList = append(quiesceList, source)
		}
		if overwrite {
			quiesceList = append(quiesceList, targetVolume)
		}
		resume := vm.quiesceVolumeContainers(quiesceList...)
		defer resume()
	}

	files, totalBytes, modeUsed, err := copyTreeFast(srcData, dstData)
	if err != nil {
		return VolumeCloneResult{}, err
	}
	syncFilesystem()

	return VolumeCloneResult{
		Source:     source,
		SourceType: sourceType,
		Target:     targetVolume,
		Files:      files,
		Bytes:      totalBytes,
		CloneMode:  modeUsed,
		DurationMs: float64(int(time.Since(started).Seconds()*100_000)) / 100,
		Quiesced:   quiesce,
	}, nil
}

func (vm *VolumeManager) DeleteSnapshot(name string) error {
	if !isValidVolumeOrSnapshotName(name) {
		return fmt.Errorf("invalid snapshot name %q", name)
	}
	vm.mu.Lock()
	defer vm.mu.Unlock()
	snapDir := filepath.Join(vm.snapshotsRoot, name)
	if _, err := os.Stat(snapDir); err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("snapshot %q not found", name)
		}
		return err
	}
	return os.RemoveAll(snapDir)
}

type fileCopyJob struct {
	src     string
	dst     string
	mode    fs.FileMode
	uid     int
	gid     int
	modTime time.Time
}

type dirTimeEntry struct {
	path    string
	mode    fs.FileMode
	uid     int
	gid     int
	modTime time.Time
}

var volCopyBufPool = sync.Pool{
	New: func() any {
		b := make([]byte, 1024*1024)
		return &b
	},
}

func copyTreeFast(srcRoot, dstRoot string) (int64, uint64, string, error) {
	if err := os.MkdirAll(dstRoot, 0o755); err != nil {
		return 0, 0, "", err
	}
	var dirs []dirTimeEntry
	var jobs []fileCopyJob

	err := filepath.WalkDir(srcRoot, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcRoot, path)
		if err != nil {
			return err
		}
		dstPath := dstRoot
		if rel != "." {
			dstPath = filepath.Join(dstRoot, rel)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		uid, gid := extractUIDGID(info)
		if d.Type()&fs.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			_ = os.Remove(dstPath)
			if err := os.Symlink(target, dstPath); err != nil {
				return err
			}
			if uid >= 0 && gid >= 0 {
				_ = os.Lchown(dstPath, uid, gid)
			}
			return nil
		}
		if d.IsDir() {
			if err := os.MkdirAll(dstPath, info.Mode().Perm()); err != nil {
				return err
			}
			dirs = append(dirs, dirTimeEntry{
				path:    dstPath,
				mode:    info.Mode().Perm(),
				uid:     uid,
				gid:     gid,
				modTime: info.ModTime(),
			})
			return nil
		}
		if d.Type().IsRegular() {
			jobs = append(jobs, fileCopyJob{
				src:     path,
				dst:     dstPath,
				mode:    info.Mode().Perm(),
				uid:     uid,
				gid:     gid,
				modTime: info.ModTime(),
			})
		}
		return nil
	})
	if err != nil {
		return 0, 0, "", err
	}

	var filesCopied atomic.Int64
	var bytesCopied atomic.Uint64
	var modeMu sync.Mutex
	selectedMode := "empty"

	if len(jobs) > 0 {
		jobCh := make(chan fileCopyJob, len(jobs))
		for _, j := range jobs {
			jobCh <- j
		}
		close(jobCh)

		var errMu sync.Mutex
		var firstErr error
		var wg sync.WaitGroup
		workers := min(8, len(jobs))
		for range workers {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for job := range jobCh {
					errMu.Lock()
					failed := firstErr != nil
					errMu.Unlock()
					if failed {
						return
					}
					n, modeUsed, cerr := copyFileFast(job.src, job.dst, job.mode, job.uid, job.gid, job.modTime)
					if cerr != nil {
						errMu.Lock()
						if firstErr == nil {
							firstErr = cerr
						}
						errMu.Unlock()
						return
					}
					filesCopied.Add(1)
					bytesCopied.Add(n)
					modeMu.Lock()
					if selectedMode == "empty" || modeUsed == "reflink" || (selectedMode == "copy" && modeUsed == "copy_file_range") {
						selectedMode = modeUsed
					}
					modeMu.Unlock()
				}
			}()
		}
		wg.Wait()
		if firstErr != nil {
			return 0, 0, "", firstErr
		}
	}

	// Restore directory ownership, permissions, and mtimes bottom-up.
	for i := len(dirs) - 1; i >= 0; i-- {
		d := dirs[i]
		if d.uid >= 0 && d.gid >= 0 {
			_ = os.Chown(d.path, d.uid, d.gid)
		}
		_ = os.Chmod(d.path, d.mode)
		_ = os.Chtimes(d.path, d.modTime, d.modTime)
	}

	return filesCopied.Load(), bytesCopied.Load(), selectedMode, nil
}

func copyFileBuffered(dst *os.File, src *os.File) (uint64, error) {
	bp := volCopyBufPool.Get().(*[]byte)
	n, err := io.CopyBuffer(dst, src, *bp)
	volCopyBufPool.Put(bp)
	if n < 0 {
		n = 0
	}
	return uint64(n), err
}
