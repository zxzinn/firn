//go:build !linux

package main

import "io"

func trySpliceHalfClose(_ io.WriteCloser, _ io.ReadCloser) bool {
	return false
}
