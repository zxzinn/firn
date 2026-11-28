package main

import (
	"bytes"
	"crypto/sha256"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVolumeSnapshotCloneIsolationAndSecurity(t *testing.T) {
	root := t.TempDir()
	volumesRoot := filepath.Join(root, "volumes")
	snapsRoot := filepath.Join(root, "snapshots")

	srcData := filepath.Join(volumesRoot, "pg-main", "_data")
	subDir := filepath.Join(srcData, "base", "16384")
	if err := os.MkdirAll(subDir, 0o750); err != nil {
		t.Fatal(err)
	}
	bigPayload := bytes.Repeat([]byte("FIRN-VOLUME-DATA-"), 8192)
	if err := os.WriteFile(filepath.Join(subDir, "table.dat"), bigPayload, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("table.dat", filepath.Join(subDir, "table.link")); err != nil {
		t.Fatal(err)
	}

	vm := NewVolumeManager(nil, volumesRoot, snapsRoot, false)

	// Path traversal rejection
	if _, err := vm.CreateSnapshot("../escape", "snap1", false); err == nil {
		t.Fatal("expected path traversal volume name rejection")
	}
	if _, err := vm.CreateSnapshot("pg-main", "../escape", false); err == nil {
		t.Fatal("expected path traversal snapshot name rejection")
	}

	// Create snapshot
	snap, err := vm.CreateSnapshot("pg-main", "snap-before-migration", false)
	if err != nil {
		t.Fatalf("CreateSnapshot failed: %v", err)
	}
	if snap.Name != "snap-before-migration" || snap.Files != 1 || snap.Bytes != uint64(len(bigPayload)) {
		t.Fatalf("unexpected snapshot info: %+v", snap)
	}

	// List snapshots
	list, err := vm.ListSnapshots()
	if err != nil || len(list) != 1 || list[0].Name != "snap-before-migration" {
		t.Fatalf("unexpected ListSnapshots result: %+v err=%v", list, err)
	}

	// Clone from snapshot
	cloneRes, err := vm.CloneVolume("snap-before-migration", "pg-wt2", true, false, false)
	if err != nil {
		t.Fatalf("CloneVolume from snapshot failed: %v", err)
	}
	if cloneRes.SourceType != "snapshot" || cloneRes.Files != 1 {
		t.Fatalf("unexpected clone result: %+v", cloneRes)
	}

	clonedFile := filepath.Join(volumesRoot, "pg-wt2", "_data", "base", "16384", "table.dat")
	gotBytes, err := os.ReadFile(clonedFile)
	if err != nil || sha256.Sum256(gotBytes) != sha256.Sum256(bigPayload) {
		t.Fatalf("cloned file content mismatch: err=%v", err)
	}
	linkTarget, err := os.Readlink(filepath.Join(volumesRoot, "pg-wt2", "_data", "base", "16384", "table.link"))
	if err != nil || linkTarget != "table.dat" {
		t.Fatalf("expected symlink preserved, got %q err=%v", linkTarget, err)
	}

	// Mutating clone must not alter source volume or snapshot
	if err := os.WriteFile(clonedFile, []byte("mutated-in-wt2"), 0o640); err != nil {
		t.Fatal(err)
	}
	srcOrig, _ := os.ReadFile(filepath.Join(subDir, "table.dat"))
	snapOrig, _ := os.ReadFile(filepath.Join(snapsRoot, "snap-before-migration", "data", "base", "16384", "table.dat"))
	if !bytes.Equal(srcOrig, bigPayload) || !bytes.Equal(snapOrig, bigPayload) {
		t.Fatal("mutating cloned volume affected source or snapshot!")
	}

	// Overwrite protection
	if _, err := vm.CloneVolume("pg-main", "pg-wt2", false, false, false); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("expected overwrite error, got %v", err)
	}
	// Clone directly from volume with overwrite=true
	directRes, err := vm.CloneVolume("pg-main", "pg-wt2", false, false, true)
	if err != nil || directRes.SourceType != "volume" {
		t.Fatalf("direct volume clone failed: %+v err=%v", directRes, err)
	}
	gotRestored, _ := os.ReadFile(clonedFile)
	if !bytes.Equal(gotRestored, bigPayload) {
		t.Fatal("expected overwrite clone to restore payload")
	}

	if vm.TotalSnapshotsBytes() != uint64(len(bigPayload)) {
		t.Fatalf("unexpected TotalSnapshotsBytes: %d", vm.TotalSnapshotsBytes())
	}

	// Delete snapshot
	if err := vm.DeleteSnapshot("snap-before-migration"); err != nil {
		t.Fatalf("DeleteSnapshot failed: %v", err)
	}
	listAfter, _ := vm.ListSnapshots()
	if len(listAfter) != 0 {
		t.Fatalf("expected 0 snapshots after delete, got %d", len(listAfter))
	}
}
