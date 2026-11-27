package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

type ProxyConfig struct {
	HTTPProxy    string `json:"httpProxy"`
	HTTPSProxy   string `json:"httpsProxy"`
	NoProxy      string `json:"noProxy"`
	VPNActive    bool   `json:"vpnActive"`
	HostDNSRelay bool   `json:"hostDnsRelay"`
}

type ProxyAndDNSRelay struct {
	engine *ReaperEngine
	mu     sync.RWMutex
	cfg    ProxyConfig
}

func NewProxyAndDNSRelay(engine *ReaperEngine) *ProxyAndDNSRelay {
	return &ProxyAndDNSRelay{
		engine: engine,
		cfg: ProxyConfig{
			HostDNSRelay: true,
		},
	}
}

func (p *ProxyAndDNSRelay) SetConfig(cfg ProxyConfig) {
	p.mu.Lock()
	p.cfg = cfg
	p.mu.Unlock()

	var script strings.Builder
	if cfg.HTTPProxy != "" || cfg.HTTPSProxy != "" || cfg.VPNActive {
		proxyURL := "http://127.0.0.1:3128"
		script.WriteString("export HTTP_PROXY=" + proxyURL + " http_proxy=" + proxyURL + "\n")
		script.WriteString("export HTTPS_PROXY=" + proxyURL + " https_proxy=" + proxyURL + "\n")
		noProxy := cfg.NoProxy
		if noProxy == "" {
			noProxy = "localhost,127.0.0.1,::1,.local,.firn.local"
		}
		script.WriteString("export NO_PROXY='" + strings.ReplaceAll(noProxy, "'", "") + "'\n")
	}
	_ = os.WriteFile("/etc/profile.d/firn-proxy.sh", []byte(script.String()), 0o644)
}

func (p *ProxyAndDNSRelay) Config() ProxyConfig {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.cfg
}

func (p *ProxyAndDNSRelay) ServeHTTPProxy(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	log.Printf("[firn-guestd] http/connect proxy relay listening on %s -> host vsock:2378", addr)
	for {
		client, err := ln.Accept()
		if err != nil {
			return err
		}
		go func(c net.Conn) {
			upstream, err := DialVsockHost(2378)
			if err != nil {
				_ = c.Close()
				return
			}
			spliceHalfClose(c, upstream)
		}(client)
	}
}

func (p *ProxyAndDNSRelay) ServeDNS(addr string) error {
	pc, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	log.Printf("[firn-guestd] dns relay listening on udp %s (vsock:2379 fallback upstream)", addr)
	buf := make([]byte, 4096)
	for {
		n, remote, err := pc.ReadFrom(buf)
		if err != nil {
			return err
		}
		pkt := append([]byte(nil), buf[:n]...)
		go func(query []byte, dest net.Addr) {
			if resp := p.handleLocalDomainQuery(query); resp != nil {
				_, _ = pc.WriteTo(resp, dest)
				return
			}
			resp, err := p.relayDNSViaVsockHost(query)
			if err == nil && len(resp) > 0 {
				_, _ = pc.WriteTo(resp, dest)
				return
			}
		}(pkt, remote)
	}
}

func (p *ProxyAndDNSRelay) relayDNSViaVsockHost(query []byte) ([]byte, error) {
	conn, err := DialVsockHost(2379)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
	var lenBuf [2]byte
	binary.BigEndian.PutUint16(lenBuf[:], uint16(len(query)))
	if _, err := conn.Write(lenBuf[:]); err != nil {
		return nil, err
	}
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return nil, err
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	if respLen == 0 || respLen > 4096 {
		return nil, fmt.Errorf("invalid dns response length %d", respLen)
	}
	resp := make([]byte, respLen)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	return resp, nil
}

func (p *ProxyAndDNSRelay) handleLocalDomainQuery(query []byte) []byte {
	qname, qtype, qend, ok := parseSimpleDNSQuery(query)
	if !ok {
		return nil
	}
	domain := strings.TrimSuffix(strings.ToLower(p.engine.Domain()), ".")
	if domain == "" {
		domain = "firn.local"
	}
	qname = strings.TrimSuffix(strings.ToLower(qname), ".")
	if qname != domain && !strings.HasSuffix(qname, "."+domain) {
		return nil
	}
	ip4 := net.ParseIP("10.87.0.1").To4()
	_, records, err := p.engine.CachedPortsAndDNS(time.Now())
	if err == nil {
		for _, rec := range records {
			for _, candidate := range rec.Names {
				if candidate == qname && rec.IP != "" {
					if parsed := net.ParseIP(rec.IP).To4(); parsed != nil {
						ip4 = parsed
						break
					}
				}
			}
		}
	}
	if qtype != 1 {
		// NODATA for AAAA / other record types inside container firn domain.
		resp := make([]byte, qend)
		copy(resp, query[:qend])
		binary.BigEndian.PutUint16(resp[2:4], 0x8180)
		binary.BigEndian.PutUint16(resp[6:8], 0)
		return resp
	}
	resp := make([]byte, 0, qend+16)
	resp = append(resp, query[:qend]...)
	binary.BigEndian.PutUint16(resp[2:4], 0x8180)
	binary.BigEndian.PutUint16(resp[6:8], 1)
	resp = append(resp,
		0xC0, 0x0C, // Pointer to QNAME
		0x00, 0x01, // TYPE A
		0x00, 0x01, // CLASS IN
		0x00, 0x00, 0x00, 0x05, // TTL 5s
		0x00, 0x04, // RDLENGTH 4
		ip4[0], ip4[1], ip4[2], ip4[3],
	)
	return resp
}

func parseSimpleDNSQuery(pkt []byte) (string, uint16, int, bool) {
	if len(pkt) < 12 || binary.BigEndian.Uint16(pkt[4:6]) < 1 {
		return "", 0, 0, false
	}
	idx := 12
	var labels []string
	for idx < len(pkt) {
		l := int(pkt[idx])
		idx++
		if l == 0 {
			break
		}
		if idx+l > len(pkt) {
			return "", 0, 0, false
		}
		labels = append(labels, string(pkt[idx:idx+l]))
		idx += l
	}
	if idx+4 > len(pkt) {
		return "", 0, 0, false
	}
	qtype := binary.BigEndian.Uint16(pkt[idx : idx+2])
	return strings.Join(labels, "."), qtype, idx + 4, true
}
