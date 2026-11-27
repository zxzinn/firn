//go:build linux

package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/fdbased"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

func openTunDevice(name string) (int, error) {
	fd, err := unix.Open("/dev/net/tun", unix.O_RDWR, 0)
	if err != nil {
		return -1, fmt.Errorf("open /dev/net/tun: %w", err)
	}
	ifr, err := unix.NewIfreq(name)
	if err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI)
	if err := unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); err != nil {
		_ = unix.Close(fd)
		return -1, fmt.Errorf("TUNSETIFF(%s): %w", name, err)
	}
	return fd, nil
}

func configureTunInterface() error {
	cmds := [][]string{
		{"addr", "replace", netstackGuestCIDR, "dev", netstackTunName},
		{"link", "set", "dev", netstackTunName, "mtu", "1500", "up"},
		{"route", "replace", "default", "via", netstackHostIP, "dev", netstackTunName, "metric", "50"},
	}
	for _, args := range cmds {
		out, err := exec.Command("ip", args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("ip %v failed: %w (%s)", args, err, string(out))
		}
	}
	return nil
}

func StartNetstack() error {
	tunFD, err := openTunDevice(netstackTunName)
	if err != nil {
		return err
	}
	if err := configureTunInterface(); err != nil {
		_ = unix.Close(tunFD)
		return err
	}

	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol, icmp.NewProtocol4},
	})

	ep, err := fdbased.New(&fdbased.Options{
		FDs: []int{tunFD},
		MTU: netstackMTU,
	})
	if err != nil {
		_ = unix.Close(tunFD)
		return fmt.Errorf("fdbased.New: %w", err)
	}

	const nicID = tcpip.NICID(1)
	if terr := s.CreateNIC(nicID, ep); terr != nil {
		_ = unix.Close(tunFD)
		return fmt.Errorf("CreateNIC: %s", terr)
	}
	if terr := s.SetPromiscuousMode(nicID, true); terr != nil {
		_ = unix.Close(tunFD)
		return fmt.Errorf("SetPromiscuousMode: %s", terr)
	}
	if terr := s.SetSpoofing(nicID, true); terr != nil {
		_ = unix.Close(tunFD)
		return fmt.Errorf("SetSpoofing: %s", terr)
	}
	s.SetRouteTable([]tcpip.Route{
		{
			Destination: header.IPv4EmptySubnet,
			NIC:         nicID,
		},
	})

	tcpFwd := tcp.NewForwarder(s, 0, 1024, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		vsockConn, err := dialHostTunnel(vsockNetTCPPort, 0x01, id.LocalAddress.String(), id.LocalPort)
		if err != nil {
			r.Complete(true)
			return
		}
		var wq waiter.Queue
		tcpEP, terr := r.CreateEndpoint(&wq)
		if terr != nil {
			_ = vsockConn.Close()
			r.Complete(true)
			return
		}
		r.Complete(false)
		tcpConn := gonet.NewTCPConn(&wq, tcpEP)
		go spliceHalfClose(tcpConn, vsockConn)
	})
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)

	udpFwd := udp.NewForwarder(s, func(r *udp.ForwarderRequest) bool {
		id := r.ID()
		var wq waiter.Queue
		udpEP, terr := r.CreateEndpoint(&wq)
		if terr != nil {
			return false
		}
		udpConn := gonet.NewUDPConn(&wq, udpEP)
		go handleNetstackUDPFlow(udpConn, id.LocalAddress.String(), id.LocalPort)
		return true
	})
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)

	log.Printf("[firn-guestd] vsock netstack active on %s (%s -> vsock:%d/%d)", netstackTunName, netstackGuestCIDR, vsockNetTCPPort, vsockNetUDPPort)
	return nil
}

func handleNetstackUDPFlow(udpConn *gonet.UDPConn, destIP string, destPort uint16) {
	defer udpConn.Close()
	vsockConn, err := dialHostTunnel(vsockNetUDPPort, 0x02, destIP, destPort)
	if err != nil {
		return
	}
	defer vsockConn.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	// Guest UDP datagrams -> host length-prefixed vsock frames
	go func() {
		defer wg.Done()
		defer func() { _ = vsockConn.Close() }()
		buf := make([]byte, 65536)
		hdr := make([]byte, 2)
		for {
			_ = udpConn.SetReadDeadline(time.Now().Add(30 * time.Second))
			n, err := udpConn.Read(buf)
			if err != nil || n == 0 {
				return
			}
			binary.BigEndian.PutUint16(hdr, uint16(n))
			if _, werr := vsockConn.Write(hdr); werr != nil {
				return
			}
			if _, werr := vsockConn.Write(buf[:n]); werr != nil {
				return
			}
		}
	}()

	// Host length-prefixed vsock frames -> guest UDP datagrams
	go func() {
		defer wg.Done()
		defer func() { _ = udpConn.Close() }()
		var hdr [2]byte
		buf := make([]byte, 65536)
		for {
			_ = vsockConn.SetReadDeadline(time.Now().Add(30 * time.Second))
			if _, err := io.ReadFull(vsockConn, hdr[:]); err != nil {
				return
			}
			plen := int(binary.BigEndian.Uint16(hdr[:]))
			if plen == 0 || plen > len(buf) {
				return
			}
			if _, err := io.ReadFull(vsockConn, buf[:plen]); err != nil {
				return
			}
			if _, err := udpConn.Write(buf[:plen]); err != nil {
				return
			}
		}
	}()

	wg.Wait()
}
