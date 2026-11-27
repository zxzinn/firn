# Changelog

All notable changes to Firn are documented in this file.

## v0.4.0

- **Hybrid `firnfs` (`AF_VSOCK:2385` + `FSEvents` Push Invalidation)**: Added a 64 MiB FUSE read/metadata cache fed by 16-worker `OP_READDIR_PREFETCH` RPCs over `AF_VSOCK:2385` and live macOS `FSEvents` invalidation, cutting 1,000-file bind-mount reads from `407.2 ms` to **`78.0 ms`** (`5.2×` faster) while passing writes/creates straight through `/mnt/virtiofs-home` (`383.6 ms` for 500 creates+writes+unlinks).
- **2-Thread Full-Duplex `AF_VSOCK` + `firn-hostnet` Jumbo Engine**:
  - Replaced single-threaded `poll()` vsock splicing with dual-thread `1 MiB` full-duplex streaming and `8 MiB` `SO_VM_SOCKETS_BUFFER` windows, boosting 128 MiB raw TCP throughput to **`921.4 / 969.0 MiB/s`**, PostgreSQL `SELECT 1` RTT to **`0.136 ms`**, PG bulk queries to **`398.3 MiB/s`**, and HTTP/1.1 Keep-Alive to **`5,197.8 req/s`**.
  - Added standalone Go `firn-hostnet` L2/L3 gVisor engine on connected `AF_UNIX SOCK_DGRAM` `MTU 16384` (`VZFileHandleNetworkDeviceAttachment`, zero `vmenet*`), concurrent `:8443` HTTPS proxy with dynamic in-memory TLS leaf certs (**`3.05 ms`**, **`2,981.8 req/s`**), `1.81 MiB/s` outbound egress, default `diskSyncMode="none"`, and `"userland-proxy": false`.
- **APFS VM Hibernation (`firn hibernate` / `firn resume`)**: Added `VMBackend` abstraction + `VZVirtualMachine.saveMachineStateTo` / `restoreMachineStateFrom` (`vm-state.vzvmsave`), dropping host footprint from `777.3 MiB` to **`21.4 MiB`** (`0 MiB` VM XPC footprint) with transparent auto-wake on incoming Docker or HTTP/HTTPS requests.
- **Built-In Kubernetes (`firn k8s`) & Multi-Distro Linux Machines (`firn machine`)**: Added single-node `k3s` (`v1.31.6+k3s1`) management with safe kubeconfig merging (preserving existing `current-context` unless `--use`) and persistent `ubuntu`/`debian`/`alpine`/`arch`/`fedora` environments sharing `$HOME` and `<name>.firn.local` DNS.
- **Opt-In Nested Virtualization (`--nested-kvm`), `utun` Direct Routing & Metal/Vulkan GPU**: Added `firn up --nested-kvm` exposing `/dev/kvm`, optional `firn route` direct host routing (`10.87.0.0/24`, `10.88.0.0/16`), and `KrunMachineRunner` (`--backend krun --gpu`) with Metal/krunkit VirtIO-GPU Venus detection.
- **UI, Packaging & Release Automation**: Added 60-sample CoreGraphics sparklines and live streaming container/machine logs in `FirnBar`, expanded Settings UI, Homebrew formula (`packaging/homebrew/firn.rb`), GitHub Release workflow (`.github/workflows/release.yml`), and `firn upgrade` with SHA-256 verification.

## v0.3.0

- **Vsock User-Space L3/L4 Netstack (`firn0`)**: Full outbound container TCP/UDP routing over `AF_VSOCK` (`vsock:2380/2381`) using gVisor netstack so container egress works seamlessly alongside macOS VPNs and `vmenet*`-limited hosts.
- **Sub-100ms Target-First Auto-Thaw + Tiered `zram` Swap**: Prioritize unpausing the targeted container first, thaw sibling containers and refresh topology asynchronously, and back cold pages with `zram0` (priority `100`) ahead of disk swapfile (priority `10`).
- **Dual-Stack Loopback Port Forwarding**: Bind both `127.0.0.1` and `[::1]` so dual-stack runtimes (Node.js, Python, curl) never hit IPv6 `ECONNREFUSED` retries.
- **Local HTTPS & Root CA**: Built-in host CA (`firn ca`) and `Network.framework` TLS proxy on `:8443` (`https://*.firn.local`) with optional `/etc/pf.anchors/dev.firn` port 80/443 redirection (`firn https`).
- **Interactive Shell & SSH Agent Forwarding**: `firn shell` PTY over `vsock:2382` (raw TTY + `SIGWINCH` resize) and automatic host `SSH_AUTH_SOCK` forwarding (`vsock:2383`).
- **Disk & Context Tooling**: `firn disk usage`, online `fstrim` (`firn disk trim`), `firn context <use|restore>`, clean `POST /poweroff` + read-only root unmount shutdown, per-project `firn.reaper.idle` label, event-driven `FirnBar` updates with a native Settings panel, and background balloon convergence.
- **Open-Source Readiness**: Apache-2.0 license, CI workflow, issue templates, contributing guide, security policy, and sanitized defaults.

## v0.2.0

- Rebranded from early prototype to **Firn**.
- Switched container storage to `overlay2` on cached APFS block attachment (`noatime,nodiratime`), event-driven `/topology` long-poll, 256 KiB / 1 MiB non-blocking `poll()` vsock splicing, native Swift `firn` CLI, `proc_pid_rusage` footprint telemetry, `*.firn.local` DNS + HTTP auto-thaw, and `Firn.app` menu bar monitor.
