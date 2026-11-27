package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/ethernet"
	"gvisor.dev/gvisor/pkg/tcpip/network/arp"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	hostNetIPStr  = "10.89.0.1"
	guestNetIPStr = "10.89.0.2"
	utunHostIPStr = "10.89.1.1"
	nicID         = tcpip.NICID(1)
)

var (
	hostMAC  = tcpip.LinkAddress([]byte{0x52, 0x54, 0x00, 0x12, 0x34, 0x01})
	guestMAC = tcpip.LinkAddress([]byte{0x52, 0x54, 0x00, 0x12, 0x34, 0x02})
)

type NetEngineConfig struct {
	MTU         uint32
	VMNetFDSock string
	UtunSock    string
	FSServer    *FirnFSServer
	FirndSock   string
}

type NetStats struct {
	FastNetActive   bool   `json:"fastNetActive"`
	MTU             uint32 `json:"mtu"`
	VMNetConnected  bool   `json:"vmnetConnected"`
	UtunConnected   bool   `json:"utunConnected"`
	FirnfsClients   int    `json:"firnfsClients"`
	RxBytes         uint64 `json:"rxBytes"`
	TxBytes         uint64 `json:"txBytes"`
	ActiveDNSCount  int    `json:"activeDnsCount"`
}

type NetEngine struct {
	cfg      NetEngineConfig
	stack    *stack.Stack
	rawEP    *dgramL2Endpoint
	ethEP    *ethernet.Endpoint
	ctx      context.Context
	cancel   context.CancelFunc
	fdLn     net.Listener
	utunSrv  *utunBridgeServer

	dnsMu      sync.RWMutex
	dnsServers []string

	lookupPaused func(ip string) (project string, container string, paused bool)

	rxBytes atomic.Uint64
	txBytes atomic.Uint64
}

type dgramL2Endpoint struct {
	mtu      uint32
	linkAddr tcpip.LinkAddress
	engine   *NetEngine

	dispMu     sync.RWMutex
	dispatcher stack.NetworkDispatcher

	fileMu sync.Mutex
	file   *os.File
	gen    uint64

	bufPool sync.Pool
}

func newDgramL2Endpoint(mtu uint32, addr tcpip.LinkAddress, engine *NetEngine) *dgramL2Endpoint {
	return &dgramL2Endpoint{
		mtu:      mtu,
		linkAddr: addr,
		engine:   engine,
		bufPool: sync.Pool{
			New: func() any {
				b := make([]byte, int(mtu)+64)
				return &b
			},
		},
	}
}

func (e *dgramL2Endpoint) currentFile() *os.File {
	e.fileMu.Lock()
	f := e.file
	e.fileMu.Unlock()
	return f
}

func (e *dgramL2Endpoint) SetFD(fd int) error {
	tuneDgramSocket(fd)
	if err := unix.SetNonblock(fd, true); err != nil {
		_ = unix.Close(fd)
		return err
	}
	f := os.NewFile(uintptr(fd), "vmnet-l2")
	if f == nil {
		_ = unix.Close(fd)
		return errors.New("os.NewFile failed")
	}

	e.fileMu.Lock()
	old := e.file
	e.file = f
	e.gen++
	gen := e.gen
	e.fileMu.Unlock()

	if old != nil {
		_ = old.Close()
	}
	go e.readLoop(f, gen)
	return nil
}

func (e *dgramL2Endpoint) readLoop(f *os.File, gen uint64) {
	buf := make([]byte, int(e.mtu)+128)
	for {
		n, err := f.Read(buf)
		if n > 0 {
			e.engine.rxBytes.Add(uint64(n))
			frame := buf[:n]
			if !e.engine.tryForwardFrameToUtun(frame) {
				pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
					Payload: buffer.MakeWithData(frame),
				})
				e.dispMu.RLock()
				d := e.dispatcher
				e.dispMu.RUnlock()
				if d != nil {
					d.DeliverNetworkPacket(0, pkt)
				}
				pkt.DecRef()
			}
		}
		if err != nil {
			if errors.Is(err, os.ErrClosed) || errors.Is(err, io.EOF) {
				return
			}
			e.fileMu.Lock()
			stillActive := e.gen == gen && e.file == f
			e.fileMu.Unlock()
			if !stillActive {
				return
			}
			time.Sleep(time.Millisecond)
		}
	}
}

func (e *dgramL2Endpoint) Close() {
	e.fileMu.Lock()
	f := e.file
	e.file = nil
	e.gen++
	e.fileMu.Unlock()
	if f != nil {
		_ = f.Close()
	}
}

func (e *dgramL2Endpoint) Attach(dispatcher stack.NetworkDispatcher) {
	e.dispMu.Lock()
	e.dispatcher = dispatcher
	e.dispMu.Unlock()
}

func (e *dgramL2Endpoint) IsAttached() bool {
	e.dispMu.RLock()
	ok := e.dispatcher != nil
	e.dispMu.RUnlock()
	return ok
}

func (e *dgramL2Endpoint) MTU() uint32                                { return e.mtu }
func (e *dgramL2Endpoint) SetMTU(mtu uint32)                          { e.mtu = mtu }
func (e *dgramL2Endpoint) Capabilities() stack.LinkEndpointCapabilities { return 0 }
func (e *dgramL2Endpoint) MaxHeaderLength() uint16                    { return 0 }
func (e *dgramL2Endpoint) LinkAddress() tcpip.LinkAddress             { return e.linkAddr }
func (e *dgramL2Endpoint) SetLinkAddress(addr tcpip.LinkAddress)      { e.linkAddr = addr }
func (e *dgramL2Endpoint) Wait()                                      {}
func (e *dgramL2Endpoint) ARPHardwareType() header.ARPHardwareType    { return header.ARPHardwareEther }
func (e *dgramL2Endpoint) AddHeader(*stack.PacketBuffer)              {}
func (e *dgramL2Endpoint) ParseHeader(*stack.PacketBuffer) bool       { return true }
func (e *dgramL2Endpoint) SetOnCloseAction(func())                    {}

func writeDgramWithBackoff(f *os.File, frame []byte) error {
	for attempt := 0; attempt < 20; attempt++ {
		_, err := f.Write(frame)
		if err == nil {
			return nil
		}
		if errors.Is(err, syscall.ENOBUFS) || errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.EWOULDBLOCK) {
			if attempt < 4 {
				runtime.Gosched()
			} else {
				time.Sleep(time.Duration(min(200, (attempt-3)*50)) * time.Microsecond)
			}
			continue
		}
		return err
	}
	return syscall.ENOBUFS
}

func (e *dgramL2Endpoint) writeRawFrame(frame []byte) tcpip.Error {
	f := e.currentFile()
	if f == nil {
		return &tcpip.ErrClosedForSend{}
	}
	if err := writeDgramWithBackoff(f, frame); err != nil {
		return &tcpip.ErrClosedForSend{}
	}
	e.engine.txBytes.Add(uint64(len(frame)))
	return nil
}

func (e *dgramL2Endpoint) WritePackets(pkts stack.PacketBufferList) (int, tcpip.Error) {
	f := e.currentFile()
	if f == nil {
		return 0, &tcpip.ErrClosedForSend{}
	}
	sent := 0
	for _, pkt := range pkts.AsSlice() {
		totalLen := pkt.Size()
		if totalLen == 0 {
			sent++
			continue
		}
		bufPtr := e.bufPool.Get().(*[]byte)
		buf := *bufPtr
		if cap(buf) < totalLen {
			buf = make([]byte, totalLen)
		} else {
			buf = buf[:totalLen]
		}
		off := 0
		for _, slice := range pkt.AsSlices() {
			off += copy(buf[off:], slice)
		}
		err := writeDgramWithBackoff(f, buf[:off])
		if cap(buf) <= cap(*bufPtr) {
			b := buf[:cap(buf)]
			e.bufPool.Put(&b)
		}
		if err != nil {
			if sent == 0 {
				return 0, &tcpip.ErrClosedForSend{}
			}
			return sent, nil
		}
		e.engine.txBytes.Add(uint64(off))
		sent++
	}
	return sent, nil
}

func tuneDgramSocket(fd int) {
	for _, pair := range [][2]int{
		{4 << 20, 1 << 20},
		{2 << 20, 512 << 10},
		{1 << 20, 256 << 10},
	} {
		_ = unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, pair[0])
		if unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_SNDBUF, pair[1]) == nil {
			return
		}
	}
}

func NewNetEngine(cfg NetEngineConfig) (*NetEngine, error) {
	if cfg.MTU == 0 {
		cfg.MTU = 16384
	}
	ctx, cancel := context.WithCancel(context.Background())
	eng := &NetEngine{
		cfg:        cfg,
		ctx:        ctx,
		cancel:     cancel,
		dnsServers: []string{"1.1.1.1", "8.8.8.8"},
	}

	s := stack.New(stack.Options{
		NetworkProtocols: []stack.NetworkProtocolFactory{
			ipv4.NewProtocol,
			arp.NewProtocol,
		},
		TransportProtocols: []stack.TransportProtocolFactory{
			tcp.NewProtocol,
			udp.NewProtocol,
			icmp.NewProtocol4,
		},
	})
	eng.stack = s

	// Tune TCP protocol options for high-bandwidth local L2 virtual link.
	sack := tcpip.TCPSACKEnabled(true)
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)
	modRecv := tcpip.TCPModerateReceiveBufferOption(true)
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &modRecv)
	rcvRange := tcpip.TCPReceiveBufferSizeRangeOption{Min: 4096, Default: 4 << 20, Max: 16 << 20}
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &rcvRange)
	sndRange := tcpip.TCPSendBufferSizeRangeOption{Min: 4096, Default: 4 << 20, Max: 16 << 20}
	_ = s.SetTransportProtocolOption(tcp.ProtocolNumber, &sndRange)

	rawEP := newDgramL2Endpoint(cfg.MTU, hostMAC, eng)
	ethEP := ethernet.NewWithNetworkMTU(rawEP)
	eng.rawEP = rawEP
	eng.ethEP = ethEP

	if terr := s.CreateNIC(nicID, ethEP); terr != nil {
		cancel()
		return nil, fmt.Errorf("CreateNIC: %s", terr)
	}
	hostAddr := tcpip.AddrFrom4Slice(netip.MustParseAddr(hostNetIPStr).AsSlice())
	guestAddr := tcpip.AddrFrom4Slice(netip.MustParseAddr(guestNetIPStr).AsSlice())
	if terr := s.AddProtocolAddress(nicID, tcpip.ProtocolAddress{
		Protocol: ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{
			Address:   hostAddr,
			PrefixLen: 24,
		},
	}, stack.AddressProperties{}); terr != nil {
		cancel()
		return nil, fmt.Errorf("AddProtocolAddress: %s", terr)
	}
	_ = s.SetPromiscuousMode(nicID, true)
	_ = s.SetSpoofing(nicID, true)

	_, subnet87, _ := net.ParseCIDR("10.87.0.0/24")
	_, subnet88, _ := net.ParseCIDR("10.88.0.0/16")
	_, subnet89, _ := net.ParseCIDR("10.89.0.0/24")
	toTcpipSubnet := func(n *net.IPNet) tcpip.Subnet {
		ones, _ := n.Mask.Size()
		m := make([]byte, 4)
		copy(m, n.Mask)
		sub, _ := tcpip.NewSubnet(tcpip.AddrFrom4Slice(n.IP.To4()), tcpip.MaskFromBytes(m))
		_ = ones
		return sub
	}
	s.SetRouteTable([]tcpip.Route{
		{Destination: toTcpipSubnet(subnet89), NIC: nicID},
		{Destination: toTcpipSubnet(subnet87), Gateway: guestAddr, NIC: nicID},
		{Destination: toTcpipSubnet(subnet88), Gateway: guestAddr, NIC: nicID},
		{Destination: header.IPv4EmptySubnet, Gateway: guestAddr, NIC: nicID},
	})
	_ = s.AddStaticNeighbor(nicID, ipv4.ProtocolNumber, guestAddr, guestMAC)

	// Start firnfs TCP server inside gVisor stack on 10.89.0.1:2385.
	if cfg.FSServer != nil {
		fsLn, err := gonet.ListenTCP(s, tcpip.FullAddress{NIC: nicID, Addr: hostAddr, Port: 2385}, ipv4.ProtocolNumber)
		if err != nil {
			cancel()
			return nil, fmt.Errorf("listen firnfs 10.89.0.1:2385: %w", err)
		}
		go func() {
			<-ctx.Done()
			_ = fsLn.Close()
		}()
		go cfg.FSServer.ServeListener(ctx, fsLn)
	}

	// Start DNS server on 10.89.0.1:53 inside gVisor stack.
	if err := eng.startStackDNS(hostAddr); err != nil {
		log.Printf("[firn-hostnet] warning: stack DNS listener failed: %v", err)
	}

	// Outbound TCP & UDP forwarders for guest traffic leaving 10.89.0.2 -> macOS internet / VPN / loopback.
	eng.installForwarders(hostAddr)

	// Accept SCM_RIGHTS socketpair fd from firnd.
	if cfg.VMNetFDSock != "" {
		if err := eng.startVMNetFDReceiver(cfg.VMNetFDSock); err != nil {
			cancel()
			return nil, err
		}
	}

	// Accept utun bridge connections if configured.
	if cfg.UtunSock != "" {
		srv, err := startUtunBridgeServer(ctx, cfg.UtunSock, eng)
		if err != nil {
			log.Printf("[firn-hostnet] warning: utun bridge socket failed: %v", err)
		} else {
			eng.utunSrv = srv
		}
	}

	return eng, nil
}

func (e *NetEngine) installForwarders(hostAddr tcpip.Address) {
	tcpFwd := tcp.NewForwarder(e.stack, 4<<20, 4096, func(r *tcp.ForwarderRequest) {
		id := r.ID()
		destIP := id.LocalAddress.String()
		// Do not intercept traffic bound for gVisor's own internal listener ports on 10.89.0.1.
		if id.LocalAddress == hostAddr && (id.LocalPort == 2385 || id.LocalPort == 53) {
			r.Complete(true)
			return
		}
		targetHost := destIP
		if destIP == hostNetIPStr {
			targetHost = "127.0.0.1"
		}
		upConn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", targetHost, id.LocalPort), 8*time.Second)
		if err != nil {
			r.Complete(true)
			return
		}
		if tc, ok := upConn.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
			_ = tc.SetReadBuffer(1 << 20)
			_ = tc.SetWriteBuffer(1 << 20)
		}
		var wq waiter.Queue
		ep, terr := r.CreateEndpoint(&wq)
		if terr != nil {
			_ = upConn.Close()
			r.Complete(true)
			return
		}
		ep.SocketOptions().SetDelayOption(false)
		r.Complete(false)
		gConn := gonet.NewTCPConn(&wq, ep)
		go spliceDual(gConn, upConn)
	})
	e.stack.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpFwd.HandlePacket)

	udpFwd := udp.NewForwarder(e.stack, func(r *udp.ForwarderRequest) bool {
		id := r.ID()
		if id.LocalAddress == hostAddr && id.LocalPort == 53 {
			return false
		}
		var wq waiter.Queue
		ep, terr := r.CreateEndpoint(&wq)
		if terr != nil {
			return false
		}
		gUDP := gonet.NewUDPConn(&wq, ep)
		targetHost := id.LocalAddress.String()
		if targetHost == hostNetIPStr {
			targetHost = "127.0.0.1"
		}
		go handleOutboundUDP(e.ctx, gUDP, targetHost, id.LocalPort)
		return true
	})
	e.stack.SetTransportProtocolHandler(udp.ProtocolNumber, udpFwd.HandlePacket)
}

func (e *NetEngine) startStackDNS(hostAddr tcpip.Address) error {
	var wq waiter.Queue
	ep, terr := e.stack.NewEndpoint(udp.ProtocolNumber, ipv4.ProtocolNumber, &wq)
	if terr != nil {
		return fmt.Errorf("new dns udp ep: %s", terr)
	}
	if berr := ep.Bind(tcpip.FullAddress{NIC: nicID, Addr: hostAddr, Port: 53}); berr != nil {
		ep.Close()
		return fmt.Errorf("bind dns udp 53: %s", berr)
	}
	pc := gonet.NewUDPConn(&wq, ep)
	go func() {
		<-e.ctx.Done()
		_ = pc.Close()
	}()
	go func() {
		buf := make([]byte, 4096)
		for {
			n, remote, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			query := append([]byte(nil), buf[:n]...)
			go func(q []byte, dst net.Addr) {
				if resp, ok := e.forwardDNSUDP(q); ok {
					_, _ = pc.WriteTo(resp, dst)
				}
			}(query, remote)
		}
	}()
	return nil
}

func (e *NetEngine) SetDNSServers(servers []string) {
	clean := make([]string, 0, len(servers)+2)
	seen := make(map[string]bool)
	for _, s := range servers {
		s = strings.TrimSpace(s)
		if s == "" || strings.HasPrefix(s, "127.") || seen[s] {
			continue
		}
		seen[s] = true
		clean = append(clean, s)
	}
	for _, fb := range []string{"1.1.1.1", "8.8.8.8"} {
		if !seen[fb] {
			clean = append(clean, fb)
		}
	}
	e.dnsMu.Lock()
	e.dnsServers = clean
	e.dnsMu.Unlock()
}

func (e *NetEngine) forwardDNSUDP(query []byte) ([]byte, bool) {
	e.dnsMu.RLock()
	servers := append([]string(nil), e.dnsServers...)
	e.dnsMu.RUnlock()
	for _, srv := range servers {
		conn, err := net.DialTimeout("udp", net.JoinHostPort(srv, "53"), 2*time.Second)
		if err != nil {
			continue
		}
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		if _, werr := conn.Write(query); werr == nil {
			resp := make([]byte, 4096)
			if n, rerr := conn.Read(resp); rerr == nil && n > 0 {
				_ = conn.Close()
				return resp[:n], true
			}
		}
		_ = conn.Close()
	}
	return nil, false
}

func (e *NetEngine) SetContainerLookup(fn func(ip string) (string, string, bool)) {
	e.lookupPaused = fn
}

func (e *NetEngine) DialGuestTCP(ctx context.Context, ipStr string, port uint16) (net.Conn, error) {
	addr, err := netip.ParseAddr(ipStr)
	if err != nil || !addr.Is4() {
		return nil, fmt.Errorf("invalid guest IP %q", ipStr)
	}
	remote := tcpip.FullAddress{
		NIC:  nicID,
		Addr: tcpip.AddrFrom4Slice(addr.AsSlice()),
		Port: port,
	}
	c, err := gonet.DialContextTCP(ctx, e.stack, remote, ipv4.ProtocolNumber)
	if err != nil {
		return nil, err
	}
	return c, nil
}

func (e *NetEngine) startVMNetFDReceiver(sockPath string) error {
	_ = os.MkdirAll(filepath.Dir(sockPath), 0o755)
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", sockPath, err)
	}
	_ = os.Chmod(sockPath, 0o600)
	e.fdLn = ln
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go e.handleVMNetFDConn(c)
		}
	}()
	return nil
}

func (e *dgramL2Endpoint) SetConnectedDgramFD(fd int) error {
	return e.SetFD(fd)
}

func (e *NetEngine) handleVMNetFDConn(c net.Conn) {
	defer c.Close()
	uc, ok := c.(*net.UnixConn)
	if !ok {
		return
	}
	buf := make([]byte, 16)
	oob := make([]byte, unix.CmsgSpace(4))
	_, oobn, _, _, err := uc.ReadMsgUnix(buf, oob)
	if err != nil {
		log.Printf("[firn-hostnet] ReadMsgUnix failed: %v", err)
		return
	}
	scms, err := unix.ParseSocketControlMessage(oob[:oobn])
	if err != nil || len(scms) == 0 {
		return
	}
	fds, err := unix.ParseUnixRights(&scms[0])
	if err != nil || len(fds) == 0 {
		return
	}
	fd := fds[0]
	for _, extra := range fds[1:] {
		_ = unix.Close(extra)
	}
	if err := e.rawEP.SetFD(fd); err != nil {
		_, _ = c.Write([]byte{0x01})
		return
	}
	_, _ = c.Write([]byte{0x00})
}

func (e *NetEngine) AttachSocketpairFD(fd int) error {
	return e.rawEP.SetFD(fd)
}

func (e *NetEngine) tryForwardFrameToUtun(ethFrame []byte) bool {
	if e.utunSrv == nil || !e.utunSrv.HasClient() {
		return false
	}
	// Quick L2 EtherType == IPv4 (0x0800) + IPv4 Dst == 10.89.1.1 check.
	if len(ethFrame) < 34 {
		return false
	}
	if binary.BigEndian.Uint16(ethFrame[12:14]) != 0x0800 {
		return false
	}
	if ethFrame[30] == 10 && ethFrame[31] == 89 && ethFrame[32] == 1 && ethFrame[33] == 1 {
		e.utunSrv.SendIPPacket(ethFrame[14:])
		return true
	}
	return false
}

func (e *NetEngine) InjectUtunIPPacket(ipPkt []byte) error {
	if len(ipPkt) < 20 || (ipPkt[0]>>4) != 4 {
		return nil
	}
	dstIP := net.IPv4(ipPkt[16], ipPkt[17], ipPkt[18], ipPkt[19]).String()
	if e.lookupPaused != nil {
		if proj, container, paused := e.lookupPaused(dstIP); paused && proj != "" {
			triggerThawHost(e.cfg.FirndSock, proj, container)
		}
	}
	frame := make([]byte, 14+len(ipPkt))
	copy(frame[0:6], guestMAC)
	copy(frame[6:12], hostMAC)
	binary.BigEndian.PutUint16(frame[12:14], 0x0800)
	copy(frame[14:], ipPkt)
	if err := e.rawEP.writeRawFrame(frame); err != nil {
		return errors.New(err.String())
	}
	return nil
}

func (e *NetEngine) Stats() NetStats {
	e.dnsMu.RLock()
	dnsCount := len(e.dnsServers)
	e.dnsMu.RUnlock()
	fsClients := 0
	if e.cfg.FSServer != nil {
		fsClients = e.cfg.FSServer.ClientCount()
	}
	return NetStats{
		FastNetActive:  true,
		MTU:            e.cfg.MTU,
		VMNetConnected: e.rawEP.currentFile() != nil,
		UtunConnected:  e.utunSrv != nil && e.utunSrv.HasClient(),
		FirnfsClients:  fsClients,
		RxBytes:        e.rxBytes.Load(),
		TxBytes:        e.txBytes.Load(),
		ActiveDNSCount: dnsCount,
	}
}

func (e *NetEngine) Close() {
	e.cancel()
	if e.fdLn != nil {
		_ = e.fdLn.Close()
	}
	if e.utunSrv != nil {
		e.utunSrv.Close()
	}
	e.rawEP.Close()
	e.stack.Close()
}

var copyBufPool = sync.Pool{
	New: func() any {
		b := make([]byte, 256*1024)
		return &b
	},
}

func spliceDual(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	copyOne := func(dst, src net.Conn) {
		defer wg.Done()
		bp := copyBufPool.Get().(*[]byte)
		_, _ = io.CopyBuffer(dst, src, *bp)
		copyBufPool.Put(bp)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	go copyOne(a, b)
	go copyOne(b, a)
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
}

func handleOutboundUDP(ctx context.Context, gUDP net.Conn, host string, port uint16) {
	defer gUDP.Close()
	up, err := net.DialTimeout("udp", fmt.Sprintf("%s:%d", host, port), 5*time.Second)
	if err != nil {
		return
	}
	defer up.Close()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		defer up.Close()
		buf := make([]byte, 65536)
		for {
			_ = gUDP.SetReadDeadline(time.Now().Add(45 * time.Second))
			n, rerr := gUDP.Read(buf)
			if n > 0 {
				if _, werr := up.Write(buf[:n]); werr != nil {
					return
				}
			}
			if rerr != nil || ctx.Err() != nil {
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		defer gUDP.Close()
		buf := make([]byte, 65536)
		for {
			_ = up.SetReadDeadline(time.Now().Add(45 * time.Second))
			n, rerr := up.Read(buf)
			if n > 0 {
				if _, werr := gUDP.Write(buf[:n]); werr != nil {
					return
				}
			}
			if rerr != nil || ctx.Err() != nil {
				return
			}
		}
	}()
	wg.Wait()
}
