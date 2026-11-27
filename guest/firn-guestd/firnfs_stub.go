//go:build !linux

package main

import "errors"

type firnFSMount struct{}

func startFirnFS(mountPoint, hostAddr string) (*firnFSMount, error) {
	return nil, errors.New("firnfs guest mount requires Linux")
}

func (m *firnFSMount) Unmount() {}
