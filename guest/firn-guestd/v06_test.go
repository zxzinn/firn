package main

import (
	"encoding/binary"
	"net"
	"testing"
	"time"
)

func buildTestDNSQuery(name string, qtype uint16) []byte {
	pkt := make([]byte, 12)
	binary.BigEndian.PutUint16(pkt[0:2], 0x1234)
	binary.BigEndian.PutUint16(pkt[2:4], 0x0100)
	binary.BigEndian.PutUint16(pkt[4:6], 1)
	for _, lbl := range splitNonEmpty(name, '.') {
		pkt = append(pkt, byte(len(lbl)))
		pkt = append(pkt, lbl...)
	}
	pkt = append(pkt, 0)
	var tail [4]byte
	binary.BigEndian.PutUint16(tail[0:2], qtype)
	binary.BigEndian.PutUint16(tail[2:4], 1)
	pkt = append(pkt, tail[:]...)
	return pkt
}

func splitNonEmpty(s string, sep byte) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == sep {
			if i > start {
				out = append(out, s[start:i])
			}
			start = i + 1
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

func TestHostDockerInternalDNSResolution(t *testing.T) {
	fd := &fakeDocker{
		containers: map[string]dockerContainerSummary{},
		inspects:   map[string]*dockerContainerInspect{},
	}
	eng := NewReaperEngine(fd, 900, "firn.local", nil)
	relay := NewProxyAndDNSRelay(eng)

	for _, alias := range []string{"host.docker.internal", "host.firn.internal", "gateway.docker.internal"} {
		resp := relay.handleLocalDomainQuery(buildTestDNSQuery(alias, 1))
		if len(resp) < 16 {
			t.Fatalf("%s A query: expected DNS answer, got len=%d", alias, len(resp))
		}
		if ancount := binary.BigEndian.Uint16(resp[6:8]); ancount != 1 {
			t.Fatalf("%s A query: expected ancount=1, got %d", alias, ancount)
		}
		gotIP := net.IP(resp[len(resp)-4:]).String()
		if gotIP != "10.89.0.1" {
			t.Fatalf("%s A query: expected 10.89.0.1, got %s", alias, gotIP)
		}

		respAAAA := relay.handleLocalDomainQuery(buildTestDNSQuery(alias, 28))
		if respAAAA == nil || binary.BigEndian.Uint16(respAAAA[6:8]) != 0 {
			t.Fatalf("%s AAAA query: expected empty NODATA response", alias)
		}
	}

	if ext := relay.handleLocalDomainQuery(buildTestDNSQuery("example.com", 1)); ext != nil {
		t.Fatalf("expected external DNS query example.com to return nil, got %x", ext)
	}
}

func TestBuildK8sDiscoveryServicesAndIngresses(t *testing.T) {
	svcJSON := `{
		"items": [
			{
				"metadata": {"name": "kubernetes", "namespace": "default"},
				"spec": {"clusterIP": "10.43.0.1", "type": "ClusterIP", "ports": [{"name": "https", "port": 443, "protocol": "TCP"}]}
			},
			{
				"metadata": {"name": "headless", "namespace": "default"},
				"spec": {"clusterIP": "None", "type": "ClusterIP", "ports": [{"name": "http", "port": 80, "protocol": "TCP"}]}
			},
			{
				"metadata": {"name": "web", "namespace": "default"},
				"spec": {"clusterIP": "10.43.10.20", "type": "ClusterIP", "ports": [{"name": "metrics", "port": 9090, "protocol": "TCP"}, {"name": "http", "port": 80, "protocol": "TCP"}]}
			},
			{
				"metadata": {"name": "api", "namespace": "staging"},
				"spec": {"clusterIP": "10.43.10.30", "type": "NodePort", "ports": [{"name": "api", "port": 8080, "protocol": "TCP"}]}
			}
		]
	}`
	ingJSON := `{
		"items": [
			{
				"metadata": {"namespace": "staging"},
				"spec": {
					"rules": [
						{
							"host": "edge.k8s.firn.local",
							"http": {"paths": [{"backend": {"service": {"name": "api", "port": {"name": "api"}}}}]}
						}
					]
				}
			}
		]
	}`

	svcs, recs := buildK8sDiscovery([]byte(svcJSON), []byte(ingJSON), "firn.local")
	if len(svcs) != 2 {
		t.Fatalf("expected 2 discovered services, got %d: %+v", len(svcs), svcs)
	}
	var sawWeb, sawAPI bool
	for _, s := range svcs {
		if s.Name == "web" && s.Namespace == "default" {
			sawWeb = true
			if s.PrimaryPort != 80 || s.ClusterIP != "10.43.10.20" {
				t.Fatalf("unexpected web service metadata: %+v", s)
			}
			if len(s.DNSNames) != 2 || s.DNSNames[0] != "web.default.k8s.firn.local" || s.DNSNames[1] != "web.k8s.firn.local" {
				t.Fatalf("unexpected web DNSNames: %+v", s.DNSNames)
			}
		}
		if s.Name == "api" && s.Namespace == "staging" {
			sawAPI = true
			if s.PrimaryPort != 8080 || len(s.DNSNames) != 2 || s.DNSNames[1] != "edge.k8s.firn.local" {
				t.Fatalf("unexpected api service/ingress merge: %+v", s)
			}
		}
	}
	if !sawWeb || !sawAPI {
		t.Fatalf("missing expected services: web=%v api=%v", sawWeb, sawAPI)
	}
	if len(recs) < 2 {
		t.Fatalf("expected DNS records for discovered services, got %d", len(recs))
	}
}

func TestReaperEngineDiskUsageDF(t *testing.T) {
	fd := &fakeDocker{
		containers: map[string]dockerContainerSummary{},
		inspects:   map[string]*dockerContainerInspect{},
		df: DockerDFSummary{
			ImagesBytes:      512 << 20,
			ContainersBytes:  32 << 20,
			VolumesBytes:     128 << 20,
			BuildCacheBytes:  256 << 20,
			ReclaimableBytes: 300 << 20,
		},
	}
	eng := NewReaperEngine(fd, 900, "firn.local", nil)
	eng.extraDNSFn = func(domain string) []DNSRecord {
		return []DNSRecord{{Names: []string{"web.default.k8s." + domain}, IP: "10.43.10.20", HTTPPort: 80}}
	}
	topo, err := eng.RefreshTopology(time.Now())
	_ = err
	if len(topo.Records) != 1 || topo.Records[0].IP != "10.43.10.20" {
		t.Fatalf("expected extraDNSFn record inside RefreshTopology without deadlock, got %+v", topo.Records)
	}
	du := eng.DiskUsage()
	if du.DockerImagesBytes != 512<<20 || du.DockerBuildCacheBytes != 256<<20 || du.DockerReclaimableBytes != 300<<20 {
		t.Fatalf("unexpected Docker DF propagation: %+v", du)
	}
}
