//go:build linux

package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func syncFilesystem() {
	unix.Sync()
}

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
	defer func() {
		if dst != nil {
			_ = dst.Close()
		}
	}()

	var copied uint64
	modeUsed := "copy"

	// 1. Try instant CoW reflink if backing filesystem supports FICLONE.
	if err := unix.IoctlFileClone(int(dst.Fd()), int(src.Fd())); err == nil {
		modeUsed = "reflink"
		if st, serr := src.Stat(); serr == nil && st.Size() > 0 {
			copied = uint64(st.Size())
		}
	} else {
		// 2. Use zero-userspace copy_file_range when supported; fall back to pooled io.CopyBuffer otherwise.
		var offsetCopied int64
		useFallback := false
		for {
			n, cerr := unix.CopyFileRange(int(src.Fd()), nil, int(dst.Fd()), nil, 4<<20, 0)
			if n > 0 {
				offsetCopied += int64(n)
			}
			if cerr == nil && n == 0 {
				copied = uint64(offsetCopied)
				modeUsed = "copy_file_range"
				break
			}
			if errors.Is(cerr, unix.EINTR) {
				continue
			}
			if offsetCopied == 0 && (errors.Is(cerr, unix.EXDEV) || errors.Is(cerr, unix.ENOSYS) || errors.Is(cerr, unix.EOPNOTSUPP) || errors.Is(cerr, unix.EINVAL)) {
				useFallback = true
				break
			}
			if cerr != nil {
				return 0, "", cerr
			}
		}
		if useFallback {
			if _, serr := src.Seek(0, io.SeekStart); serr != nil {
				return 0, "", serr
			}
			n, berr := copyFileBuffered(dst, src)
			if berr != nil {
				return 0, "", berr
			}
			copied = n
			modeUsed = "copy"
		}
	}

	if uid >= 0 && gid >= 0 {
		_ = dst.Chown(uid, gid)
	}
	_ = dst.Chmod(mode)
	if err := dst.Close(); err != nil {
		dst = nil
		return 0, "", err
	}
	dst = nil
	_ = os.Chtimes(dstPath, modTime, modTime)
	return copied, modeUsed, nil
}
