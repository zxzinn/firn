//go:build linux

package main

import (
	"errors"
	"io"
	"os"
	"sync/atomic"
	"syscall"

	"golang.org/x/sys/unix"
)

var spliceUnsupported atomic.Bool

func trySpliceHalfClose(dst io.WriteCloser, src io.ReadCloser) bool {
	if spliceUnsupported.Load() {
		return false
	}
	scSrc, okSrc := src.(syscall.Conn)
	scDst, okDst := dst.(syscall.Conn)
	if !okSrc || !okDst {
		return false
	}
	rcSrc, err1 := scSrc.SyscallConn()
	rcDst, err2 := scDst.SyscallConn()
	if err1 != nil || err2 != nil {
		return false
	}

	var pipeFDs [2]int
	if err := unix.Pipe2(pipeFDs[:], unix.O_CLOEXEC|unix.O_NONBLOCK); err != nil {
		return false
	}
	pipeR := os.NewFile(uintptr(pipeFDs[0]), "splice-r")
	pipeW := os.NewFile(uintptr(pipeFDs[1]), "splice-w")
	defer pipeR.Close()
	defer pipeW.Close()

	_, _ = unix.FcntlInt(uintptr(pipeFDs[1]), unix.F_SETPIPE_SZ, 1<<20)

	const maxSpliceChunk = 1 << 20
	var transferred int64
	var inPipe int64

	drainPipeFallback := func(n int64) bool {
		if n <= 0 {
			return true
		}
		buf := make([]byte, min(int(n), 256*1024))
		rem := n
		for rem > 0 {
			nr, rerr := pipeR.Read(buf[:min(len(buf), int(rem))])
			if nr > 0 {
				written := 0
				for written < nr {
					nw, werr := dst.Write(buf[written:nr])
					if nw > 0 {
						written += nw
					}
					if werr != nil {
						return false
					}
				}
				rem -= int64(nr)
			}
			if rerr != nil {
				return false
			}
		}
		return true
	}

	for {
		var rErr error
		var eof bool
		var got int64
		cErr := rcSrc.Read(func(fd uintptr) bool {
			for {
				n, err := unix.Splice(int(fd), nil, pipeFDs[1], nil, maxSpliceChunk, unix.SPLICE_F_MOVE|unix.SPLICE_F_NONBLOCK)
				if n > 0 {
					got += n
					return true
				}
				if err == nil {
					eof = true
					return true
				}
				if errors.Is(err, unix.EAGAIN) {
					return false
				}
				if errors.Is(err, unix.EINTR) {
					continue
				}
				rErr = err
				return true
			}
		})
		if cErr != nil {
			return transferred > 0
		}
		if rErr != nil {
			if transferred == 0 && inPipe == 0 && (errors.Is(rErr, unix.EINVAL) || errors.Is(rErr, unix.ENOSYS) || errors.Is(rErr, unix.EOPNOTSUPP)) {
				// One side does not support splice; fall back cleanly to pooled io.CopyBuffer.
				if _, isVsock := src.(*vsockConn); isVsock {
					spliceUnsupported.Store(true)
				}
				return false
			}
			return true
		}
		if got == 0 && eof {
			return true
		}
		inPipe += got

		for inPipe > 0 {
			var wErr error
			var wrote int64
			cwErr := rcDst.Write(func(fd uintptr) bool {
				for inPipe > 0 {
					chunk := min(int(inPipe), maxSpliceChunk)
					n, err := unix.Splice(pipeFDs[0], nil, int(fd), nil, chunk, unix.SPLICE_F_MOVE|unix.SPLICE_F_NONBLOCK)
					if n > 0 {
						inPipe -= n
						wrote += n
						transferred += n
						continue
					}
					if errors.Is(err, unix.EAGAIN) {
						return false
					}
					if errors.Is(err, unix.EINTR) {
						continue
					}
					wErr = err
					return true
				}
				return true
			})
			if cwErr != nil {
				return true
			}
			if wErr != nil {
				if transferred == 0 && (errors.Is(wErr, unix.EINVAL) || errors.Is(wErr, unix.ENOSYS) || errors.Is(wErr, unix.EOPNOTSUPP)) {
					_ = drainPipeFallback(inPipe)
					inPipe = 0
					if _, isVsock := dst.(*vsockConn); isVsock {
						spliceUnsupported.Store(true)
					}
					// Bytes already read from src have been drained; finish remaining stream cleanly here.
					bufPtr := copyBufPool.Get().(*[]byte)
					_, _ = io.CopyBuffer(dst, src, *bufPtr)
					copyBufPool.Put(bufPtr)
					return true
				}
				return true
			}
			_ = wrote
		}
	}
}
