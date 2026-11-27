//go:build !linux

package main

func interfaceHasIPv4(ifaceName, wantIP string) bool {
	return false
}

func StartNetstack() error {
	return nil
}
