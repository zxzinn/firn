# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities responsibly via GitHub Security Advisories for this repository rather than opening a public issue.

Include a clear description of the issue, affected component (`firnd`, `firn`, `FirnBar`, `firn-guestd`, or TLS/DNS/proxy handling), and reproduction steps.

## Threat Model Notes

- `firnd` binds host UNIX sockets (`~/.firn/run/{firnd,docker,shell}.sock`) with `0600` permissions.
- Loopback proxies and DNS listeners bind strictly to `127.0.0.1` and `[::1]`.
- `firn ca install` generates a per-machine root CA in `~/.firn/certs/ca.crt` whose private key (`ca.key`, `0600`) stays exclusively on your host filesystem.
