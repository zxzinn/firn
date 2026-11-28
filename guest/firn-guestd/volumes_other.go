//go:build !linux

package main

import (
	"io/fs"
	"os"
	"syscall"
	"time"
)

func syncFilesystem() {}

func extractUIDGID(fi fs.FileInfo) (int, int) {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && st != nil {
		return int(st.Uid), int(st.Gid)
	}
	return -1, -1
}

func copyFileFast(srcPath, dstPath string, mode fs.FileMode, uid, gid int, modTime time.Time) (uint64, string, error) {
	src, err := os.Open(srcPath)
	if err != nil {
		return 0, "", err
	}
	defer src.Close()

	dst, err := os.OpenFile(dstPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return 0, "", err
	}
	copied, err := copyFileBuffered(dst, src)
	if err != nil {
		_ = dst.Close()
		return 0, "", err
	}
	if uid >= 0 && gid >= 0 {
		_ = dst.Chown(uid, gid)
	}
	_ = dst.Chmod(mode)
	if err := dst.Close(); err != nil {
		return 0, "", err
	}
	_ = os.Chtimes(dstPath, modTime, modTime)
	return copied, "copy", nil
}
