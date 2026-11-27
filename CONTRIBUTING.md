# Contributing to Firn

Thank you for your interest in contributing to Firn!

## Development Requirements

- Apple Silicon (or Intel) Mac with macOS 14+ and Apple `Virtualization.framework`
- Xcode Command Line Tools (`swift`)
- Go (`guest/firn-guestd/go.mod`)
- Docker CLI + Compose v2 (`docker`) and a working Linux container engine for initial Alpine rootfs assembly (`BUILD_DOCKER_CONTEXT`)

## Project Layout

- `Sources/FirnCore/` — Shared configuration, local DNS server, host CA/cert generation, metrics, and IPC client
- `Sources/firnd/` — Host daemon managing `VZVirtualMachine`, `virtio-vsock` bridges, dual-stack TCP/HTTP/HTTPS proxies, and balloon memory control
- `Sources/firn/` — Native Swift CLI (`up`, `down`, `status`, `shell`, `ca`, `https`, `disk`, `context`, `bench`, `doctor`, `autostart`)
- `Sources/FirnBar/` — Native AppKit menu bar monitor and settings window
- `guest/firn-guestd/` — Static `linux/arm64` Go guest daemon (`AF_VSOCK` bridges, gVisor user-space netstack, PTY shell, cgroup v2 freeze/reclaim)
- `guest/init`, `guest/build-rootfs.sh` — Minimal Alpine init and rootfs image builder

## Running Checks Before Submitting a PR

```sh
make test
```

If you modified `guest/firn-guestd`, `guest/init`, or `guest/build-rootfs.sh`, rebuild the rootfs cleanly before testing live:

```sh
build/firn down
BUILD_DOCKER_CONTEXT=orbstack make build
```

All pull requests are validated against GitHub Actions CI (`.github/workflows/ci.yml`). By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](./LICENSE).
