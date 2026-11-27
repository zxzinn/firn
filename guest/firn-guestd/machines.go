package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	machineContainerPrefix = "firn-machine-"
	machineLabel           = "firn.machine"
	machineNameLabel       = "firn.machine.name"
	machineDistroLabel     = "firn.machine.distro"
	machineImageLabel      = "firn.machine.image"
)

type LinuxMachineInfo struct {
	Name        string `json:"name"`
	Distro      string `json:"distro"`
	Image       string `json:"image"`
	Container   string `json:"container"`
	State       string `json:"state"`
	IP          string `json:"ip,omitempty"`
	MemoryBytes uint64 `json:"memoryBytes"`
	DNSName     string `json:"dnsName"`
}

type MachineCreateRequest struct {
	Name     string `json:"name"`
	Distro   string `json:"distro"`
	Image    string `json:"image"`
	HostHome string `json:"hostHome,omitempty"`
}

func resolveMachineImage(distro, explicitImage string) (resolvedDistro string, resolvedImage string) {
	if explicitImage != "" {
		d := strings.ToLower(strings.TrimSpace(distro))
		if d == "" {
			d = strings.Split(explicitImage, ":")[0]
		}
		return d, explicitImage
	}
	switch strings.ToLower(strings.TrimSpace(distro)) {
	case "", "ubuntu":
		return "ubuntu", "ubuntu:24.04"
	case "debian":
		return "debian", "debian:12"
	case "alpine":
		return "alpine", "alpine:3.21"
	case "arch", "archlinux":
		return "arch", "archlinux:latest"
	case "fedora":
		return "fedora", "fedora:41"
	default:
		return strings.ToLower(strings.TrimSpace(distro)), distro
	}
}

func sanitizeMachineName(raw string) (string, error) {
	clean := sanitizeDNSLabel(raw)
	if clean == "" {
		return "", fmt.Errorf("invalid machine name %q", raw)
	}
	return clean, nil
}

func machineContainerName(name string) string {
	return machineContainerPrefix + name
}

func ListLinuxMachines(eng *ReaperEngine, domain string) ([]LinuxMachineInfo, error) {
	items, err := eng.docker.ListContainers()
	if err != nil {
		return nil, err
	}
	if domain == "" {
		domain = "firn.local"
	}
	out := make([]LinuxMachineInfo, 0)
	for _, item := range items {
		if item.Labels[machineLabel] != "true" {
			continue
		}
		name := item.Labels[machineNameLabel]
		if name == "" && len(item.Names) > 0 {
			name = strings.TrimPrefix(strings.TrimPrefix(item.Names[0], "/"), machineContainerPrefix)
		}
		distro := item.Labels[machineDistroLabel]
		image := item.Labels[machineImageLabel]
		var ip string
		var mem uint64
		if item.State == "running" || item.State == "paused" {
			if ins, ierr := eng.docker.InspectContainer(item.ID); ierr == nil && ins != nil {
				for _, netInfo := range ins.NetworkSettings.Networks {
					if netInfo.IPAddress != "" {
						ip = netInfo.IPAddress
						break
					}
				}
				if cg := DiscoverCgroupDir(ins.State.Pid, item.ID, eng.procRoot, eng.cgroupRoot); cg != "" {
					mem = readUint64File(filepath.Join(cg, "memory.current"))
				}
			}
		}
		cname := machineContainerName(name)
		if len(item.Names) > 0 {
			cname = strings.TrimPrefix(item.Names[0], "/")
		}
		out = append(out, LinuxMachineInfo{
			Name:        name,
			Distro:      distro,
			Image:       image,
			Container:   cname,
			State:       item.State,
			IP:          ip,
			MemoryBytes: mem,
			DNSName:     sanitizeDNSLabel(name) + "." + strings.TrimSuffix(domain, "."),
		})
	}
	return out, nil
}

func CreateLinuxMachine(eng *ReaperEngine, req MachineCreateRequest, defaultHostHome string) (LinuxMachineInfo, error) {
	name, err := sanitizeMachineName(req.Name)
	if err != nil {
		return LinuxMachineInfo{}, err
	}
	distro, image := resolveMachineImage(req.Distro, req.Image)
	cname := machineContainerName(name)
	hostHome := req.HostHome
	if hostHome == "" {
		hostHome = defaultHostHome
	}

	args := []string{
		"run", "-d",
		"--name", cname,
		"--hostname", name,
		"--restart", "unless-stopped",
		"--label", machineLabel + "=true",
		"--label", machineNameLabel + "=" + name,
		"--label", machineDistroLabel + "=" + distro,
		"--label", machineImageLabel + "=" + image,
		"--label", exemptLabel + "=true",
		"-e", "SSH_AUTH_SOCK=" + guestSSHAgentSock,
		"-v", cname + "-home:/root",
		"-v", guestSSHAgentSock + ":" + guestSSHAgentSock,
	}
	if hostHome != "" {
		if _, stErr := os.Stat(hostHome); stErr == nil {
			args = append(args, "-v", hostHome+":"+hostHome, "-w", hostHome)
		}
	}
	args = append(args, "--entrypoint", "/bin/sh", image, "-c", "while true; do sleep 3600; done")

	if out, cerr := exec.Command("docker", args...).CombinedOutput(); cerr != nil {
		return LinuxMachineInfo{}, fmt.Errorf("docker run machine %s failed: %w (%s)", name, cerr, strings.TrimSpace(string(out)))
	}
	_, _ = eng.RefreshTopology(time.Now())
	list, err := ListLinuxMachines(eng, eng.Domain())
	if err == nil {
		for _, m := range list {
			if m.Name == name {
				return m, nil
			}
		}
	}
	return LinuxMachineInfo{
		Name:      name,
		Distro:    distro,
		Image:     image,
		Container: cname,
		State:     "running",
		DNSName:   name + "." + strings.TrimSuffix(eng.Domain(), "."),
	}, nil
}

func ControlLinuxMachine(eng *ReaperEngine, name, action string) error {
	clean, err := sanitizeMachineName(name)
	if err != nil {
		return err
	}
	cname := machineContainerName(clean)
	var cmd *exec.Cmd
	switch action {
	case "start":
		cmd = exec.Command("docker", "start", cname)
	case "stop":
		cmd = exec.Command("docker", "stop", "-t", "3", cname)
	case "delete":
		cmd = exec.Command("docker", "rm", "-f", cname)
	default:
		return fmt.Errorf("unknown machine action %q", action)
	}
	if out, cerr := cmd.CombinedOutput(); cerr != nil {
		return fmt.Errorf("docker %s %s failed: %w (%s)", action, cname, cerr, strings.TrimSpace(string(out)))
	}
	if action == "delete" {
		_ = exec.Command("docker", "volume", "rm", "-f", cname+"-home").Run()
	}
	_, _ = eng.RefreshTopology(time.Now())
	return nil
}

func CloneLinuxMachine(eng *ReaperEngine, srcName, dstName, defaultHostHome string) (LinuxMachineInfo, error) {
	srcClean, err := sanitizeMachineName(srcName)
	if err != nil {
		return LinuxMachineInfo{}, err
	}
	dstClean, err := sanitizeMachineName(dstName)
	if err != nil {
		return LinuxMachineInfo{}, err
	}
	if srcClean == dstClean {
		return LinuxMachineInfo{}, fmt.Errorf("target machine name %q must differ from source", dstClean)
	}
	machines, err := ListLinuxMachines(eng, eng.Domain())
	if err != nil {
		return LinuxMachineInfo{}, err
	}
	var srcMachine *LinuxMachineInfo
	for i := range machines {
		if machines[i].Name == srcClean {
			srcMachine = &machines[i]
			break
		}
	}
	if srcMachine == nil {
		return LinuxMachineInfo{}, fmt.Errorf("source machine %q not found", srcClean)
	}
	srcCname := srcMachine.Container
	if srcCname == "" {
		srcCname = machineContainerName(srcClean)
	}
	cloneImage := "firn-machine-clone/" + dstClean + ":latest"
	if out, cerr := exec.Command("docker", "commit", srcCname, cloneImage).CombinedOutput(); cerr != nil {
		return LinuxMachineInfo{}, fmt.Errorf("docker commit %s failed: %w (%s)", srcCname, cerr, strings.TrimSpace(string(out)))
	}
	srcVol := srcCname + "-home"
	dstVol := machineContainerName(dstClean) + "-home"
	if exec.Command("docker", "volume", "inspect", srcVol).Run() == nil {
		if out, verr := exec.Command("docker", "volume", "create", dstVol).CombinedOutput(); verr != nil {
			return LinuxMachineInfo{}, fmt.Errorf("docker volume create %s failed: %w (%s)", dstVol, verr, strings.TrimSpace(string(out)))
		}
		cpCmd := exec.Command("docker", "run", "--rm",
			"-v", srcVol+":/from:ro",
			"-v", dstVol+":/to",
			"--entrypoint", "/bin/sh",
			cloneImage,
			"-c", "cp -a /from/. /to/",
		)
		if out, cerr := cpCmd.CombinedOutput(); cerr != nil {
			return LinuxMachineInfo{}, fmt.Errorf("clone home volume %s -> %s failed: %w (%s)", srcVol, dstVol, cerr, strings.TrimSpace(string(out)))
		}
	}
	return CreateLinuxMachine(eng, MachineCreateRequest{
		Name:     dstClean,
		Distro:   srcMachine.Distro,
		Image:    cloneImage,
		HostHome: defaultHostHome,
	}, defaultHostHome)
}
