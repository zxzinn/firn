# Changelog

All notable changes to Firn are documented in this file.

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
