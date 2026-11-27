//go:build darwin

package main

import (
	"net"
	"os/exec"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

func statAtimeNs(st *syscall.Stat_t) int64 { return st.Atimespec.Nano() }
func statMtimeNs(st *syscall.Stat_t) int64 { return st.Mtimespec.Nano() }
func statCtimeNs(st *syscall.Stat_t) int64 { return st.Ctimespec.Nano() }

const (
	utunControlName = "com.apple.net.utun_control"
	utunOptIfname   = 2
	pfSystem        = 32
	sysprotoControl = 2
	afSysControl    = 2
	ctliocginfo     = 0xc0644e03
)

type ctlInfo struct {
	ctlID   uint32
	ctlName [96]byte
}

type sockaddrCtl struct {
	scLen      uint8
	scFamily   uint8
	ssSysaddr  uint16
	scID       uint32
	scUnit     uint32
	scReserved [5]uint32
}

func openUtunDevice() (int, string, error) {
	fd, err := unix.Socket(pfSystem, unix.SOCK_DGRAM, sysprotoControl)
	if err != nil {
		return -1, "", err
	}
	var info ctlInfo
	copy(info.ctlName[:], utunControlName)
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uintptr(ctliocginfo), uintptr(unsafe.Pointer(&info)))
	if errno != 0 {
		_ = unix.Close(fd)
		return -1, "", errno
	}
	sc := sockaddrCtl{
		scLen:     uint8(unsafe.Sizeof(sockaddrCtl{})),
		scFamily:  unix.AF_SYSTEM,
		ssSysaddr: afSysControl,
		scID:      info.ctlID,
		scUnit:    0, // allocate next free utunN
	}
	_, _, errno = unix.Syscall(unix.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&sc)), uintptr(sc.scLen))
	if errno != 0 {
		_ = unix.Close(fd)
		return -1, "", errno
	}
	nameBytes := make([]byte, 32)
	nameLen := uint32(len(nameBytes))
	_, _, errno = unix.Syscall6(
		unix.SYS_GETSOCKOPT,
		uintptr(fd),
		uintptr(sysprotoControl),
		uintptr(utunOptIfname),
		uintptr(unsafe.Pointer(&nameBytes[0])),
		uintptr(unsafe.Pointer(&nameLen)),
		0,
	)
	if errno != 0 {
		_ = unix.Close(fd)
		return -1, "", errno
	}
	ifname := string(nameBytes[:max(0, int(nameLen)-1)])
	return fd, ifname, nil
}

func configureUtunRoutes(ifname string) error {
	cmds := [][]string{
		{"/sbin/ifconfig", ifname, "inet", "10.89.1.1", "10.89.1.2", "netmask", "255.255.255.0", "mtu", "16000", "up"},
		{"/sbin/route", "-n", "add", "-net", "10.87.0.0/24", "-interface", ifname},
		{"/sbin/route", "-n", "add", "-net", "10.88.0.0/16", "-interface", ifname},
	}
	for _, cmd := range cmds {
		if out, err := exec.Command(cmd[0], cmd[1:]...).CombinedOutput(); err != nil {
			_ = out
			if cmd[0] == "/sbin/ifconfig" {
				return err
			}
		}
	}
	return nil
}

func cleanupUtunRoutes(ifname string) {
	for _, netCIDR := range []string{"10.87.0.0/24", "10.88.0.0/16"} {
		_ = exec.Command("/sbin/route", "-n", "delete", "-net", netCIDR).Run()
	}
	if ifname != "" {
		_ = exec.Command("/sbin/ifconfig", ifname, "down").Run()
	}
}

func isIPv4UtunTarget(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	return (ip4[0] == 10 && ip4[1] == 87 && ip4[2] == 0) || (ip4[0] == 10 && ip4[1] == 88)
}
