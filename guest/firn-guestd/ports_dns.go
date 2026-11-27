package main

import (
	"strconv"
	"strings"
)

type PortMapping struct {
	HostPort      int    `json:"hostPort"`
	GuestPort     int    `json:"guestPort"`
	GuestHost     string `json:"guestHost"`
	Project       string `json:"project,omitempty"`
	Service       string `json:"service"`
	ContainerName string `json:"containerName"`
	ContainerIP   string `json:"containerIP,omitempty"`
	Paused        bool   `json:"paused"`
}

type DNSRecord struct {
	Names         []string `json:"names"`
	ContainerName string   `json:"containerName"`
	Project       string   `json:"project,omitempty"`
	Service       string   `json:"service"`
	IP            string   `json:"ip"`
	HTTPPort      int      `json:"httpPort,omitempty"`
	Paused        bool     `json:"paused"`
}

func extractContainerPorts(info *dockerContainerInspect, project, service, name, ip string, paused bool) []PortMapping {
	if info == nil {
		return nil
	}
	var out []PortMapping
	seenHost := make(map[int]bool)
	for protoKey, bindings := range info.NetworkSettings.Ports {
		portStr, proto, ok := strings.Cut(protoKey, "/")
		if !ok || proto != "tcp" {
			continue
		}
		guestPort, err := strconv.Atoi(portStr)
		if err != nil || guestPort <= 0 {
			continue
		}
		for _, binding := range bindings {
			hostPort, err := strconv.Atoi(binding.HostPort)
			if err != nil || hostPort <= 0 || seenHost[hostPort] {
				continue
			}
			seenHost[hostPort] = true
			out = append(out, PortMapping{
				HostPort:      hostPort,
				GuestPort:     guestPort,
				GuestHost:     "127.0.0.1",
				Project:       project,
				Service:       service,
				ContainerName: name,
				ContainerIP:   ip,
				Paused:        paused,
			})
		}
	}
	return out
}

func pickPrimaryHTTPPort(ports []PortMapping) int {
	preferred := []int{80, 3000, 8080, 8025, 8000, 5173, 5174, 8333, 6333}
	for _, want := range preferred {
		for _, p := range ports {
			if p.GuestPort == want || p.HostPort == want {
				return p.GuestPort
			}
		}
	}
	if len(ports) > 0 {
		return ports[0].GuestPort
	}
	return 0
}

func sanitizeDNSLabel(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	var b strings.Builder
	for _, r := range raw {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			b.WriteRune(r)
		} else if r == '_' || r == '.' || r == ' ' {
			b.WriteByte('-')
		}
	}
	return strings.Trim(b.String(), "-")
}

func buildContainerDNSNames(name, service, project, domain string, ports []PortMapping) ([]string, int) {
	if domain == "" {
		domain = "firn.local"
	}
	domain = strings.TrimSuffix(strings.ToLower(domain), ".")
	var names []string
	seen := make(map[string]bool)
	add := func(fqdn string) {
		if fqdn != "" && !seen[fqdn] {
			seen[fqdn] = true
			names = append(names, fqdn)
		}
	}
	cleanName := sanitizeDNSLabel(name)
	cleanService := sanitizeDNSLabel(service)
	cleanProject := sanitizeDNSLabel(project)
	if cleanName != "" {
		add(cleanName + "." + domain)
	}
	if cleanProject != "" && cleanService != "" {
		add(cleanService + "." + cleanProject + "." + domain)
	}
	if cleanService == "mailpit" && cleanProject != "" {
		add("mail." + cleanProject + "." + domain)
	}
	return names, pickPrimaryHTTPPort(ports)
}
