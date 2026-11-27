#!/usr/bin/env python3
"""Reproducible cross-runtime benchmark suite for Firn and OrbStack.

Uses only the Python 3 standard library on the host (plus a tiny compiled
static Go micro-helper binary mounted read-only into Alpine containers when a
Go toolchain is available, falling back to python:3.13-alpine otherwise).

Safety guarantees:
  * Never touches pre-existing containers, volumes, images, or networks.
  * Names every created Docker resource with the `firn-bench-` prefix and
    removes them in `finally:` blocks.
  * Never modifies the user's default Docker context (`docker context show`).
  * Binds ephemeral loopback host ports probed at runtime so it never collides
    with existing services.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import http.client
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import ssl
import statistics
import struct
import subprocess
import sys
import threading
import time
from typing import Any


RESOURCE_PREFIX = "firn-bench-"
ALPINE_IMAGE = "alpine:3.21"
POSTGRES_IMAGE = "postgres:18-alpine"
VALKEY_IMAGE = "valkey/valkey:9.1.3-alpine"
MAILPIT_IMAGE = "axllent/mailpit:v1.31.0"
EGRESS_URL = (
    "https://dl-cdn.alpinelinux.org/alpine/v3.21/main/aarch64/APKINDEX.tar.gz"
)
PG_BULK_ROWS = 20185
PG_BULK_ROW_BYTES = 1000  # 20,185,000 bytes == 19.25 MiB (1024^2)


HELPER_GO_SRC = r"""package main

import (
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func mustJSON(kv map[string]any) {
	parts := make([]string, 0, len(kv))
	for k, v := range kv {
		switch val := v.(type) {
		case string:
			parts = append(parts, fmt.Sprintf("%q:%q", k, val))
		case bool:
			parts = append(parts, fmt.Sprintf("%q:%t", k, val))
		case int, int64:
			parts = append(parts, fmt.Sprintf("%q:%d", k, val))
		case float64:
			parts = append(parts, fmt.Sprintf("%q:%.3f", k, val))
		default:
			parts = append(parts, fmt.Sprintf("%q:%v", k, val))
		}
	}
	fmt.Println("{" + strings.Join(parts, ",") + "}")
}

func runFsBurst(args []string) {
	fsFlags := flag.NewFlagSet("fsburst", flag.ExitOnError)
	dir := fsFlags.String("dir", "/data/burst", "target directory")
	count := fsFlags.Int("count", 1000, "file count")
	size := fsFlags.Int("size", 4096, "file size bytes")
	doFsync := fsFlags.Bool("fsync", true, "fsync each file")
	_ = fsFlags.Parse(args)

	if err := os.MkdirAll(*dir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir failed: %v\n", err)
		os.Exit(1)
	}
	payload := make([]byte, *size)
	for i := range payload {
		payload[i] = byte('a' + (i % 26))
	}
	paths := make([]string, *count)
	for i := 0; i < *count; i++ {
		paths[i] = filepath.Join(*dir, "f_"+strconv.Itoa(i)+".bin")
	}

	t0 := time.Now()
	for _, p := range paths {
		f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "open failed: %v\n", err)
			os.Exit(1)
		}
		if _, err := f.Write(payload); err != nil {
			_ = f.Close()
			fmt.Fprintf(os.Stderr, "write failed: %v\n", err)
			os.Exit(1)
		}
		if *doFsync {
			if err := syscall.Fsync(int(f.Fd())); err != nil {
				_ = f.Close()
				fmt.Fprintf(os.Stderr, "fsync failed: %v\n", err)
				os.Exit(1)
			}
		}
		_ = f.Close()
	}
	createDur := time.Since(t0)

	t1 := time.Now()
	for _, p := range paths {
		if err := os.Remove(p); err != nil {
			fmt.Fprintf(os.Stderr, "unlink failed: %v\n", err)
			os.Exit(1)
		}
	}
	unlinkDur := time.Since(t1)
	totalDur := createDur + unlinkDur
	opsPerSec := float64(*count) / totalDur.Seconds()
	mustJSON(map[string]any{
		"count":       *count,
		"bytes":       *size,
		"fsync":       *doFsync,
		"create_ms":   float64(createDur.Microseconds()) / 1000.0,
		"unlink_ms":   float64(unlinkDur.Microseconds()) / 1000.0,
		"total_ms":    float64(totalDur.Microseconds()) / 1000.0,
		"ops_per_sec": opsPerSec,
	})
}

func runReadTree(args []string) {
	rtFlags := flag.NewFlagSet("readtree", flag.ExitOnError)
	dir := rtFlags.String("dir", "/work", "directory to read")
	_ = rtFlags.Parse(args)

	buf := make([]byte, 65536)
	var files int64
	var totalBytes int64
	t0 := time.Now()
	err := filepath.WalkDir(*dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !d.Type().IsRegular() {
			return err
		}
		f, oerr := os.Open(path)
		if oerr != nil {
			return oerr
		}
		for {
			n, rerr := f.Read(buf)
			totalBytes += int64(n)
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				_ = f.Close()
				return rerr
			}
		}
		_ = f.Close()
		files++
		return nil
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "walk failed: %v\n", err)
		os.Exit(1)
	}
	dur := time.Since(t0)
	mustJSON(map[string]any{
		"files":    files,
		"bytes":    totalBytes,
		"total_ms": float64(dur.Microseconds()) / 1000.0,
	})
}

func runTCPSink(args []string) {
	fl := flag.NewFlagSet("tcp-sink", flag.ExitOnError)
	listenAddr := fl.String("listen", ":9000", "listen address")
	_ = fl.Parse(args)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("READY")
	buf := make([]byte, 256*1024)
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetNoDelay(true)
			}
			var total int64
			for {
				n, rerr := c.Read(buf)
				total += int64(n)
				if rerr != nil {
					break
				}
			}
			_, _ = fmt.Fprintf(c, "%d\n", total)
		}(conn)
	}
}

func runTCPSource(args []string) {
	fl := flag.NewFlagSet("tcp-source", flag.ExitOnError)
	listenAddr := fl.String("listen", ":9001", "listen address")
	totalBytes := fl.Int64("bytes", 128*1024*1024, "bytes to stream")
	_ = fl.Parse(args)

	ln, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("READY")
	chunk := make([]byte, 256*1024)
	for i := range chunk {
		chunk[i] = byte(i)
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetNoDelay(true)
			}
			rem := *totalBytes
			for rem > 0 {
				n := int64(len(chunk))
				if rem < n {
					n = rem
				}
				w, werr := c.Write(chunk[:n])
				rem -= int64(w)
				if werr != nil {
					return
				}
			}
		}(conn)
	}
}

func main() {
	if len(os.Args) < 2 {
		os.Exit(2)
	}
	switch os.Args[1] {
	case "fsburst":
		runFsBurst(os.Args[2:])
	case "readtree":
		runReadTree(os.Args[2:])
	case "tcp-sink":
		runTCPSink(os.Args[2:])
	case "tcp-source":
		runTCPSource(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", os.Args[1])
		os.Exit(2)
	}
}
"""


@dataclass
class RunResult:
    code: int
    stdout: str
    stderr: str
    duration_ms: float


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    timeout: float = 120.0,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> RunResult:
    """Execute a subprocess and measure wall-clock duration in milliseconds."""
    t0 = time.perf_counter()
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    res = RunResult(proc.returncode, proc.stdout, proc.stderr, round(elapsed_ms, 2))
    if check and res.code != 0:
        raise RuntimeError(
            f"Command failed ({res.code}): {' '.join(cmd)}\n"
            f"stdout: {res.stdout.strip()}\nstderr: {res.stderr.strip()}"
        )
    return res


def docker_cmd(
    context: str,
    args: list[str],
    *,
    timeout: float = 180.0,
    check: bool = True,
) -> RunResult:
    return run_cmd(
        ["docker", "--context", context, *args], timeout=timeout, check=check
    )


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = (len(ordered) - 1) * (pct / 100.0)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return round(ordered[int(idx)], 3)
    frac = idx - lo
    return round(ordered[lo] * (1.0 - frac) + ordered[hi] * frac, 3)


def alloc_free_port(reserved: set[int]) -> int:
    """Probe an ephemeral TCP port free on both 127.0.0.1 and ::1."""
    for _ in range(64):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s4:
            s4.bind(("127.0.0.1", 0))
            port = int(s4.getsockname()[1])
        if port in reserved:
            continue
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s6:
                s6.bind(("::1", port))
        except OSError:
            continue
        reserved.add(port)
        return port
    raise RuntimeError("Failed to allocate an ephemeral loopback port")


def parse_dd_output(stderr_text: str) -> tuple[int, float]:
    """Parse BusyBox/GNU dd transfer bytes and elapsed seconds."""
    m = re.search(
        r"(\d+)\s+bytes\b.*?copied,\s*([0-9]+(?:\.[0-9]+)?)\s+s(?:econds)?",
        stderr_text,
    )
    if not m:
        raise RuntimeError(f"Could not parse dd output:\n{stderr_text}")
    return int(m.group(1)), float(m.group(2))


def find_go_command(repo_root: Path) -> list[str] | None:
    """Locate a working Go toolchain (direct PATH or mise shim in guest dir)."""
    if shutil.which("go"):
        probe = run_cmd(["go", "version"], check=False)
        if probe.code == 0:
            return ["go"]
    mise = shutil.which("mise")
    if mise:
        guest_dir = repo_root / "guest" / "firn-guestd"
        if guest_dir.is_dir():
            probe = run_cmd(
                [mise, "exec", "go", "--", "go", "version"],
                cwd=guest_dir,
                check=False,
            )
            if probe.code == 0:
                return [mise, "exec", "go", "--", "go"]
            probe = run_cmd(
                [mise, "exec", "go@1.27.4", "--", "go", "version"],
                cwd=guest_dir,
                check=False,
            )
            if probe.code == 0:
                return [mise, "exec", "go@1.27.4", "--", "go"]
    return None


def build_helper_binary(repo_root: Path, tmp_dir: Path, arch: str) -> Path | None:
    """Compile a static Linux helper binary for exact in-container timings."""
    go_cmd = find_go_command(repo_root)
    if not go_cmd:
        return None
    helper_dir = tmp_dir / "helper"
    helper_dir.mkdir(parents=True, exist_ok=True)
    src = helper_dir / "main.go"
    src.write_text(HELPER_GO_SRC, encoding="utf-8")
    (helper_dir / "go.mod").write_text(
        "module firn-bench-helper\n\ngo 1.21\n", encoding="utf-8"
    )
    out_bin = tmp_dir / "bin" / "firn-bench-helper"
    out_bin.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CGO_ENABLED"] = "0"
    env["GOOS"] = "linux"
    env["GOARCH"] = "arm64" if arch in ("arm64", "aarch64") else "amd64"
    run_cmd(
        [*go_cmd, "build", "-ldflags=-s -w", "-o", str(out_bin), str(src)],
        cwd=helper_dir,
        env=env,
    )
    out_bin.chmod(0o755)
    return out_bin


def read_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("Unexpected EOF on socket")
        buf.extend(chunk)
    return bytes(buf)


class PgWireClient:
    """Minimal pure-stdlib PostgreSQL v3 wire-protocol benchmark client."""

    def __init__(self, host: str, port: int, user: str = "postgres", database: str = "postgres") -> None:
        self.sock = socket.create_connection((host, port), timeout=30.0)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        params = f"user\x00{user}\x00database\x00{database}\x00\x00".encode("utf-8")
        startup = struct.pack(">II", 8 + len(params), 196608) + params
        self.sock.sendall(startup)
        self._wait_ready(password="")

    def _read_msg(self) -> tuple[str, bytes]:
        hdr = read_exact(self.sock, 5)
        mtype = chr(hdr[0])
        mlen = struct.unpack(">I", hdr[1:5])[0]
        payload = read_exact(self.sock, mlen - 4) if mlen > 4 else b""
        return mtype, payload

    def _wait_ready(self, password: str) -> None:
        while True:
            mtype, payload = self._read_msg()
            if mtype == "R":
                auth_code = struct.unpack(">I", payload[:4])[0]
                if auth_code == 0:
                    continue
                if auth_code == 3:
                    pw = password.encode("utf-8") + b"\x00"
                    self.sock.sendall(b"p" + struct.pack(">I", 4 + len(pw)) + pw)
                    continue
                raise RuntimeError(f"Unsupported PostgreSQL auth code {auth_code}")
            if mtype == "E":
                raise RuntimeError(f"PostgreSQL error: {payload!r}")
            if mtype == "Z":
                return

    def simple_query(self, sql: str) -> tuple[int, int]:
        raw = sql.encode("utf-8") + b"\x00"
        self.sock.sendall(b"Q" + struct.pack(">I", 4 + len(raw)) + raw)
        rows = 0
        total_bytes = 0
        while True:
            mtype, payload = self._read_msg()
            if mtype == "D":
                rows += 1
                ncols = struct.unpack(">H", payload[:2])[0]
                pos = 2
                for _ in range(ncols):
                    col_len = struct.unpack(">i", payload[pos : pos + 4])[0]
                    pos += 4
                    if col_len > 0:
                        total_bytes += col_len
                        pos += col_len
            elif mtype == "E":
                raise RuntimeError(f"PostgreSQL query error: {payload!r}")
            elif mtype == "Z":
                return rows, total_bytes

    def prepare(self, name: str, sql: str) -> None:
        pkt = (
            b"P"
            + struct.pack(
                ">I",
                4 + len(name) + 1 + len(sql) + 1 + 2,
            )
            + name.encode("utf-8")
            + b"\x00"
            + sql.encode("utf-8")
            + b"\x00"
            + struct.pack(">H", 0)
        )
        sync = b"S\x00\x00\x00\x04"
        self.sock.sendall(pkt + sync)
        while True:
            mtype, payload = self._read_msg()
            if mtype == "E":
                raise RuntimeError(f"PostgreSQL prepare error: {payload!r}")
            if mtype == "Z":
                return

    def execute_prepared(self, name: str) -> tuple[int, int]:
        stmt_b = name.encode("utf-8") + b"\x00"
        bind_body = b"\x00" + stmt_b + struct.pack(">HHH", 0, 0, 0)
        bind = b"B" + struct.pack(">I", 4 + len(bind_body)) + bind_body
        exec_body = b"\x00" + struct.pack(">I", 0)
        execute = b"E" + struct.pack(">I", 4 + len(exec_body)) + exec_body
        sync = b"S\x00\x00\x00\x04"
        self.sock.sendall(bind + execute + sync)
        rows = 0
        total_bytes = 0
        while True:
            mtype, payload = self._read_msg()
            if mtype == "D":
                rows += 1
                ncols = struct.unpack(">H", payload[:2])[0]
                pos = 2
                for _ in range(ncols):
                    col_len = struct.unpack(">i", payload[pos : pos + 4])[0]
                    pos += 4
                    if col_len > 0:
                        total_bytes += col_len
                        pos += col_len
            elif mtype == "E":
                raise RuntimeError(f"PostgreSQL execute error: {payload!r}")
            elif mtype == "Z":
                return rows, total_bytes

    def close(self) -> None:
        try:
            self.sock.sendall(b"X\x00\x00\x00\x04")
        except OSError:
            pass
        self.sock.close()


def detect_firn_bin(repo_root: Path, explicit: str, name: str) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    candidate = repo_root / "build" / name
    if candidate.is_file():
        return candidate
    found = shutil.which(name)
    return Path(found) if found else None


def firn_is_running() -> bool:
    pid_file = Path.home() / ".firn" / "run" / "firnd.pid"
    if not pid_file.is_file():
        return False
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def firn_cli(firn_bin: Path, args: list[str], *, timeout: float = 60.0) -> RunResult:
    return run_cmd([str(firn_bin), *args], timeout=timeout)


def firn_status_json(firn_bin: Path) -> dict[str, Any]:
    res = firn_cli(firn_bin, ["status", "--json"])
    return json.loads(res.stdout)


def firn_disk_json(firn_bin: Path) -> dict[str, Any]:
    res = firn_cli(firn_bin, ["disk", "usage", "--json"])
    return json.loads(res.stdout)


def count_vmenet_interfaces() -> int:
    res = run_cmd(["/sbin/ifconfig", "-l"], check=False)
    if res.code != 0:
        return -1
    return sum(1 for item in res.stdout.split() if item.startswith("vmenet"))


def parse_top_mem(raw: str) -> float:
    """Convert macOS top MEM column (e.g. 745M+, 10G, 8176K-) to MiB."""
    clean = raw.strip().rstrip("+-")
    if not clean:
        return 0.0
    unit = clean[-1].upper()
    try:
        val = float(clean[:-1]) if unit in ("K", "M", "G", "T") else float(clean)
    except ValueError:
        return 0.0
    if unit == "K":
        return val / 1024.0
    if unit == "M":
        return val
    if unit == "G":
        return val * 1024.0
    if unit == "T":
        return val * 1024.0 * 1024.0
    return val / (1024.0 * 1024.0)


def sample_host_processes(
    firnd_pid: int | None = None, *, interval_sec: int = 5
) -> dict[str, Any]:
    """Sample exact CPU% (via `top -l 2 -s <interval>`) and RSS (via `ps`)."""
    ps_res = run_cmd(["/bin/ps", "-A", "-o", "pid=,rss=,comm="])
    firn_pids: list[int] = []
    orb_pids: list[int] = []
    rss_by_pid: dict[int, float] = {}
    for line in ps_res.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            rss_mib = int(parts[1]) / 1024.0
        except ValueError:
            continue
        comm = parts[2]
        if firnd_pid and pid == firnd_pid:
            firn_pids.append(pid)
            rss_by_pid[pid] = rss_mib
        elif "com.apple.Virtualization.VirtualMachine" in comm:
            firn_pids.append(pid)
            rss_by_pid[pid] = rss_mib
        elif "OrbStack Helper" in comm:
            orb_pids.append(pid)
            rss_by_pid[pid] = rss_mib

    top_res = run_cmd(
        ["top", "-l", "2", "-s", str(interval_sec), "-stats", "pid,cpu,mem"],
        timeout=float(interval_sec * 4 + 15),
    )
    # Only read the 2nd sample (after the 2nd "PID %CPU MEM" header).
    lines = top_res.stdout.splitlines()
    header_indices = [
        i for i, ln in enumerate(lines) if ln.strip().startswith("PID") and "%CPU" in ln
    ]
    sample_lines = lines[header_indices[-1] + 1 :] if header_indices else []
    cpu_by_pid: dict[int, float] = {}
    mem_by_pid: dict[int, float] = {}
    for ln in sample_lines:
        cols = ln.split()
        if len(cols) < 3:
            continue
        try:
            pid = int(cols[0])
            cpu = float(cols[1])
        except ValueError:
            continue
        cpu_by_pid[pid] = cpu
        mem_by_pid[pid] = parse_top_mem(cols[2])

    return {
        "firn": {
            "pids": firn_pids,
            "cpu_percent": round(sum(cpu_by_pid.get(p, 0.0) for p in firn_pids), 2),
            "rss_mib": round(sum(rss_by_pid.get(p, 0.0) for p in firn_pids), 1),
            "top_mem_mib": round(sum(mem_by_pid.get(p, 0.0) for p in firn_pids), 1),
        },
        "orbstack_helper": {
            "pids": orb_pids,
            "cpu_percent": round(sum(cpu_by_pid.get(p, 0.0) for p in orb_pids), 2),
            "rss_mib": round(sum(rss_by_pid.get(p, 0.0) for p in orb_pids), 1),
            "top_mem_mib": round(sum(mem_by_pid.get(p, 0.0) for p in orb_pids), 1),
        },
    }


def ensure_images(context: str, images: list[str]) -> None:
    for img in images:
        chk = docker_cmd(context, ["image", "inspect", img], check=False)
        if chk.code != 0:
            print(f"[{context}] Pulling missing image {img}...", file=sys.stderr)
            docker_cmd(context, ["pull", img], timeout=300.0)


def write_compose_file(
    path: Path,
    pg_port: int,
    valkey_port: int,
    mailpit_port: int,
    *,
    include_postgres: bool = True,
) -> None:
    lines = ["services:"]
    if include_postgres:
        lines.extend(
            [
                "  postgres:",
                f"    image: {POSTGRES_IMAGE}",
                "    environment:",
                "      POSTGRES_PASSWORD: bench",
                "      POSTGRES_USER: postgres",
                "      POSTGRES_DB: bench",
                "    ports:",
                f'      - "127.0.0.1:{pg_port}:5432"',
                "    healthcheck:",
                '      test: ["CMD-SHELL", "pg_isready -U postgres -d bench"]',
                "      interval: 200ms",
                "      timeout: 2s",
                "      retries: 40",
                "      start_period: 0s",
            ]
        )
    lines.extend(
        [
            "  valkey:",
            f"    image: {VALKEY_IMAGE}",
            "    ports:",
            f'      - "127.0.0.1:{valkey_port}:6379"',
            "    healthcheck:",
            '      test: ["CMD", "valkey-cli", "ping"]',
            "      interval: 200ms",
            "      timeout: 2s",
            "      retries: 40",
            "      start_period: 0s",
            "  mailpit:",
            f"    image: {MAILPIT_IMAGE}",
            "    ports:",
            f'      - "127.0.0.1:{mailpit_port}:8025"',
            "    healthcheck:",
            '      test: ["CMD", "/mailpit", "readyz"]',
            "      interval: 200ms",
            "      timeout: 2s",
            "      retries: 40",
            "      start_period: 0s",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def wait_http_ok(host: str, port: int, path: str, timeout_s: float = 15.0) -> None:
    deadline = time.monotonic() + timeout_s
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        conn: http.client.HTTPConnection | None = None
        try:
            conn = http.client.HTTPConnection(host, port, timeout=2.0)
            conn.request("GET", path)
            resp = conn.getresponse()
            resp.read()
            if resp.status == 200:
                return
        except Exception as exc:
            last_err = exc
        finally:
            if conn is not None:
                conn.close()
        time.sleep(0.05)
    raise RuntimeError(f"HTTP probe http://{host}:{port}{path} failed: {last_err}")


def wait_https_firn_ok(
    fqdn: str, https_port: int, path: str, ca_cert: Path, timeout_s: float = 10.0
) -> float:
    ssl_ctx = ssl.create_default_context(cafile=str(ca_cert))
    deadline = time.monotonic() + timeout_s
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        t0 = time.perf_counter()
        conn: http.client.HTTPSConnection | None = None
        try:
            conn = http.client.HTTPSConnection(
                "127.0.0.1", https_port, timeout=5.0, context=ssl_ctx
            )
            raw = socket.create_connection(("127.0.0.1", https_port), timeout=5.0)
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.sock = ssl_ctx.wrap_socket(raw, server_hostname=fqdn)
            conn.request(
                "GET",
                path,
                headers={"Host": f"{fqdn}:{https_port}", "Connection": "close"},
            )
            resp = conn.getresponse()
            resp.read()
            if resp.status == 200:
                return round((time.perf_counter() - t0) * 1000.0, 2)
            last_err = RuntimeError(f"Unexpected status: {resp.status}")
        except Exception as exc:
            last_err = exc
        finally:
            if conn is not None:
                conn.close()
        time.sleep(0.1)
    raise RuntimeError(f"HTTPS probe https://{fqdn}:{https_port}{path} failed: {last_err}")


def bench_http_endpoint(
    *,
    host: str,
    port: int,
    path: str,
    total_requests: int = 500,
    concurrency: int = 16,
    keep_alive: bool = True,
    tls_fqdn: str | None = None,
    ca_cert: Path | None = None,
) -> dict[str, Any]:
    """Run concurrent HTTP/1.1 requests and measure RPS, p50, and p95 latency."""
    ssl_ctx = (
        ssl.create_default_context(cafile=str(ca_cert))
        if (tls_fqdn and ca_cert)
        else None
    )
    tls = threading.local()
    lock = threading.Lock()
    counter = {"next": 0}
    latencies: list[float] = []

    def next_idx() -> int | None:
        with lock:
            if counter["next"] >= total_requests:
                return None
            idx = counter["next"]
            counter["next"] += 1
            return idx

    def make_conn() -> http.client.HTTPConnection:
        if ssl_ctx is not None:
            conn = http.client.HTTPSConnection(
                "127.0.0.1", port, timeout=10.0, context=ssl_ctx
            )
            # Connect socket manually to set SNI to tls_fqdn while dialing 127.0.0.1.
            raw = socket.create_connection(("127.0.0.1", port), timeout=10.0)
            raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.sock = ssl_ctx.wrap_socket(raw, server_hostname=tls_fqdn)
            return conn
        conn = http.client.HTTPConnection(host, port, timeout=10.0)
        conn.connect()
        if conn.sock is not None:
            conn.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return conn

    headers = {"Host": f"{tls_fqdn}:{port}"} if tls_fqdn else {}
    if not keep_alive:
        headers["Connection"] = "close"

    def worker() -> None:
        local_lats: list[float] = []
        while True:
            if next_idx() is None:
                break
            t0 = time.perf_counter()
            if keep_alive:
                conn = getattr(tls, "conn", None)
                for attempt in range(2):
                    try:
                        if conn is None:
                            conn = make_conn()
                            tls.conn = conn
                        conn.request("GET", path, headers=headers)
                        resp = conn.getresponse()
                        resp.read()
                        if resp.status != 200:
                            raise RuntimeError(f"HTTP {resp.status}")
                        break
                    except Exception:
                        if conn is not None:
                            conn.close()
                        tls.conn = None
                        conn = None
                        if attempt == 1:
                            raise
            else:
                conn = make_conn()
                try:
                    conn.request("GET", path, headers=headers)
                    resp = conn.getresponse()
                    resp.read()
                    if resp.status != 200:
                        raise RuntimeError(f"HTTP {resp.status}")
                finally:
                    conn.close()
            local_lats.append((time.perf_counter() - t0) * 1000.0)
        with lock:
            latencies.extend(local_lats)

    # Warm up connection pool when keep-alive is enabled.
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        t_start = time.perf_counter()
        futs = [pool.submit(worker) for _ in range(concurrency)]
        for f in futs:
            f.result()
        total_s = time.perf_counter() - t_start

    return {
        "requests": total_requests,
        "concurrency": concurrency,
        "keep_alive": keep_alive,
        "total_ms": round(total_s * 1000.0, 2),
        "rps": round(total_requests / total_s, 1),
        "p50_ms": percentile(latencies, 50.0),
        "p95_ms": percentile(latencies, 95.0),
    }


def bench_context(
    context: str,
    categories: set[int],
    tmp_dir: Path,
    helper_bin: Path | None,
    firn_bin: Path | None,
) -> dict[str, Any]:
    """Run Categories 1..6 against a single Docker context with full cleanup."""
    results: dict[str, Any] = {"context": context}
    reserved_ports: set[int] = set()
    compose_dir = tmp_dir / f"compose-{context}"
    compose_dir.mkdir(parents=True, exist_ok=True)
    compose_file = compose_dir / "compose.yml"
    compose_project = f"{RESOURCE_PREFIX}stack-{context}"
    vol_name = f"{RESOURCE_PREFIX}vol-{context}"
    pg_container = f"{RESOURCE_PREFIX}pg-{context}"
    tcp_container = f"{RESOURCE_PREFIX}tcp-{context}"
    build_img = f"{RESOURCE_PREFIX}img-{context}"
    tree_dir = tmp_dir / f"tree-{context}"
    build_dir = tmp_dir / f"buildctx-{context}"

    compose_is_up = False
    try:
        needed_images = [ALPINE_IMAGE]
        if 1 in categories or 4 in categories:
            needed_images.extend([POSTGRES_IMAGE, VALKEY_IMAGE, MAILPIT_IMAGE])
        ensure_images(context, list(dict.fromkeys(needed_images)))

        # Category 1: Lifecycle & CLI Latency (+ launch stack for Cat 4 HTTP reuse)
        if 1 in categories or 4 in categories:
            ver_times: list[float] = []
            alpine_times: list[float] = []
            pg_times: list[float] = []
            if 1 in categories:
                # One unmeasured warmup ensures CLI/socket state is warm.
                docker_cmd(context, ["version", "--format", "{{.Server.Version}}"])
                for _ in range(5):
                    ver_times.append(
                        docker_cmd(
                            context, ["version", "--format", "{{.Server.Version}}"]
                        ).duration_ms
                    )
                docker_cmd(context, ["run", "--rm", ALPINE_IMAGE, "true"])
                for _ in range(5):
                    alpine_times.append(
                        docker_cmd(
                            context, ["run", "--rm", ALPINE_IMAGE, "true"]
                        ).duration_ms
                    )
                docker_cmd(
                    context,
                    ["run", "--rm", "--entrypoint", "true", POSTGRES_IMAGE],
                )
                for _ in range(5):
                    pg_times.append(
                        docker_cmd(
                            context,
                            ["run", "--rm", "--entrypoint", "true", POSTGRES_IMAGE],
                        ).duration_ms
                    )

            pg_port = alloc_free_port(reserved_ports)
            valkey_port = alloc_free_port(reserved_ports)
            mailpit_port = alloc_free_port(reserved_ports)
            write_compose_file(compose_file, pg_port, valkey_port, mailpit_port)

            # Warm cycle first if measuring Cat 1 compose latency so layers/networks exist.
            if 1 in categories:
                docker_cmd(
                    context,
                    ["compose", "-p", compose_project, "-f", str(compose_file), "up", "-d", "--wait"],
                    timeout=180.0,
                )
                compose_is_up = True
                docker_cmd(
                    context,
                    ["compose", "-p", compose_project, "-f", str(compose_file), "down", "-v", "--remove-orphans"],
                    timeout=120.0,
                )
                compose_is_up = False

            up_res = docker_cmd(
                context,
                ["compose", "-p", compose_project, "-f", str(compose_file), "up", "-d", "--wait"],
                timeout=180.0,
            )
            compose_is_up = True
            wait_http_ok("127.0.0.1", mailpit_port, "/api/v1/info")

            # Run Cat 4 HTTP 1.1 benchmark against the live Mailpit container before tearing down.
            cat4_http: dict[str, Any] = {}
            if 4 in categories:
                cat4_http["http_keepalive"] = bench_http_endpoint(
                    host="127.0.0.1",
                    port=mailpit_port,
                    path="/api/v1/info",
                    total_requests=500,
                    concurrency=16,
                    keep_alive=True,
                )
                cat4_http["http_conn_per_req"] = bench_http_endpoint(
                    host="127.0.0.1",
                    port=mailpit_port,
                    path="/api/v1/info",
                    total_requests=500,
                    concurrency=16,
                    keep_alive=False,
                )
                if context == "firn":
                    ca_cert = Path.home() / ".firn" / "certs" / "ca.crt"
                    if ca_cert.is_file():
                        fqdn = f"mailpit.{compose_project}.firn.local"
                        probe_ms = wait_https_firn_ok(
                            fqdn, 8443, "/api/v1/info", ca_cert, timeout_s=10.0
                        )
                        curl_res = run_cmd(
                            [
                                "curl",
                                "-sS",
                                "--cacert",
                                str(ca_cert),
                                "--resolve",
                                f"{fqdn}:8443:127.0.0.1",
                                "-o",
                                "/dev/null",
                                "-w",
                                "%{http_code} %{time_total}",
                                f"https://{fqdn}:8443/api/v1/info",
                            ]
                        )
                        code_str, sec_str = curl_res.stdout.strip().split()
                        cat4_http["https_firn_local_curl"] = {
                            "url": f"https://{fqdn}:8443/api/v1/info",
                            "http_code": int(code_str),
                            "ms": round(float(sec_str) * 1000.0, 2),
                            "probe_ms": probe_ms,
                        }
                        cat4_http["https_firn_local_500_conn_per_req"] = (
                            bench_http_endpoint(
                                host="127.0.0.1",
                                port=8443,
                                path="/api/v1/info",
                                total_requests=500,
                                concurrency=16,
                                keep_alive=False,
                                tls_fqdn=fqdn,
                                ca_cert=ca_cert,
                            )
                        )

            down_res = docker_cmd(
                context,
                ["compose", "-p", compose_project, "-f", str(compose_file), "down", "-v", "--remove-orphans"],
                timeout=120.0,
            )
            compose_is_up = False

            if 1 in categories:
                results["cat1_lifecycle"] = {
                    "docker_version_runs_ms": ver_times,
                    "docker_version_median_ms": round(statistics.median(ver_times), 2),
                    "alpine_run_runs_ms": alpine_times,
                    "alpine_run_median_ms": round(statistics.median(alpine_times), 2),
                    "postgres_entrypoint_true_runs_ms": pg_times,
                    "postgres_entrypoint_true_median_ms": round(
                        statistics.median(pg_times), 2
                    ),
                    "compose_up_wait_ms": up_res.duration_ms,
                    "compose_down_ms": down_res.duration_ms,
                }
            if 4 in categories:
                results.setdefault("cat4_network", {}).update(cat4_http)

        # Category 2: Native VM Named-Volume Disk I/O
        if 2 in categories:
            docker_cmd(context, ["volume", "rm", "-f", vol_name], check=False)
            docker_cmd(context, ["volume", "create", vol_name])
            try:
                wr = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{vol_name}:/data",
                        ALPINE_IMAGE,
                        "dd",
                        "if=/dev/zero",
                        "of=/data/test.bin",
                        "bs=1M",
                        "count=256",
                        "conv=fsync",
                    ],
                )
                wr_bytes, wr_sec = parse_dd_output(wr.stderr)
                rd = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{vol_name}:/data",
                        ALPINE_IMAGE,
                        "dd",
                        "if=/data/test.bin",
                        "of=/dev/null",
                        "bs=1M",
                    ],
                )
                rd_bytes, rd_sec = parse_dd_output(rd.stderr)

                burst_info: dict[str, Any]
                if helper_bin is not None:
                    burst_res = docker_cmd(
                        context,
                        [
                            "run",
                            "--rm",
                            "-v",
                            f"{vol_name}:/data",
                            "-v",
                            f"{helper_bin.parent}:/bench:ro",
                            ALPINE_IMAGE,
                            "/bench/firn-bench-helper",
                            "fsburst",
                            "-dir",
                            "/data/burst",
                            "-count",
                            "1000",
                            "-size",
                            "4096",
                            "-fsync=true",
                        ],
                    )
                    burst_info = json.loads(burst_res.stdout.strip())
                else:
                    ensure_images(context, ["python:3.13-alpine"])
                    py_script = (
                        "import os,time; d='/data/burst'; os.makedirs(d,exist_ok=True);"
                        "p=[f'{d}/f_{i}.bin' for i in range(1000)]; data=b'x'*4096; t0=time.perf_counter();"
                        "\nfor f in p:\n fd=os.open(f,os.O_CREAT|os.O_WRONLY|os.O_TRUNC); os.write(fd,data); os.fsync(fd); os.close(fd)"
                        "\nt1=time.perf_counter()"
                        "\nfor f in p:\n os.unlink(f)"
                        "\nt2=time.perf_counter(); tot=(t2-t0)*1000; import json; print(json.dumps({'count':1000,'bytes':4096,'fsync':True,'create_ms':round((t1-t0)*1000,3),'unlink_ms':round((t2-t1)*1000,3),'total_ms':round(tot,3),'ops_per_sec':round(1000/(t2-t0),3)}))"
                    )
                    burst_res = docker_cmd(
                        context,
                        [
                            "run",
                            "--rm",
                            "-v",
                            f"{vol_name}:/data",
                            "python:3.13-alpine",
                            "python3",
                            "-c",
                            py_script,
                        ],
                    )
                    burst_info = json.loads(burst_res.stdout.strip())

                results["cat2_volume_io"] = {
                    "seq_write_256mib_mib_s": round(
                        (wr_bytes / (1024 * 1024)) / wr_sec, 1
                    ),
                    "seq_write_256mib_ms": round(wr_sec * 1000.0, 2),
                    "seq_write_container_wall_ms": wr.duration_ms,
                    "seq_read_256mib_mib_s": round(
                        (rd_bytes / (1024 * 1024)) / rd_sec, 1
                    ),
                    "seq_read_256mib_ms": round(rd_sec * 1000.0, 2),
                    "seq_read_container_wall_ms": rd.duration_ms,
                    "small_file_burst_1000x4k_fsync_unlink": burst_info,
                }
            finally:
                docker_cmd(context, ["volume", "rm", "-f", vol_name], check=False)

        # Category 3: Bind Mount / VirtioFS Host-Shared I/O
        if 3 in categories:
            if tree_dir.exists():
                shutil.rmtree(tree_dir)
            payload_1k = b"f" * 1024
            for d_idx in range(50):
                sub = tree_dir / f"d{d_idx:02d}"
                sub.mkdir(parents=True, exist_ok=True)
                for f_idx in range(20):
                    (sub / f"file_{f_idx:02d}.dat").write_bytes(payload_1k)
            (tree_dir / "rw").mkdir(exist_ok=True)

            walk_times: list[float] = []
            for _ in range(3):
                wres = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{tree_dir}:/work",
                        ALPINE_IMAGE,
                        "sh",
                        "-c",
                        "find /work -type f | wc -l",
                    ],
                )
                count_val = int(wres.stdout.strip())
                if count_val != 1000:
                    raise RuntimeError(f"Expected 1000 files in walk, got {count_val}")
                walk_times.append(wres.duration_ms)

            if helper_bin is not None:
                read_res = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{tree_dir}:/work",
                        "-v",
                        f"{helper_bin.parent}:/bench:ro",
                        ALPINE_IMAGE,
                        "/bench/firn-bench-helper",
                        "readtree",
                        "-dir",
                        "/work",
                    ],
                )
                read_info = json.loads(read_res.stdout.strip())

                rw_res = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{tree_dir}:/work",
                        "-v",
                        f"{helper_bin.parent}:/bench:ro",
                        ALPINE_IMAGE,
                        "/bench/firn-bench-helper",
                        "fsburst",
                        "-dir",
                        "/work/rw",
                        "-count",
                        "500",
                        "-size",
                        "4096",
                        "-fsync=false",
                    ],
                )
                rw_info = json.loads(rw_res.stdout.strip())
            else:
                read_res = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{tree_dir}:/work",
                        ALPINE_IMAGE,
                        "sh",
                        "-c",
                        "find /work -type f -exec cat {} + >/dev/null",
                    ],
                )
                read_info = {"files": 1000, "total_ms": read_res.duration_ms}
                rw_res = docker_cmd(
                    context,
                    [
                        "run",
                        "--rm",
                        "-v",
                        f"{tree_dir}:/work",
                        ALPINE_IMAGE,
                        "sh",
                        "-c",
                        "i=0; while [ $i -lt 500 ]; do dd if=/dev/zero of=/work/rw/f_$i bs=4096 count=1 status=none; i=$((i+1)); done; rm -f /work/rw/f_*",
                    ],
                )
                rw_info = {"count": 500, "bytes": 4096, "total_ms": rw_res.duration_ms}

            results["cat3_virtiofs"] = {
                "tree_walk_1000_files_runs_ms": walk_times,
                "tree_walk_1000_files_cold_ms": walk_times[0],
                "tree_walk_1000_files_median_ms": round(
                    statistics.median(walk_times), 2
                ),
                "read_1000_files_in_container_ms": read_info["total_ms"],
                "read_1000_files_wall_ms": read_res.duration_ms,
                "create_write_remove_500x4k_in_container_ms": rw_info["total_ms"],
                "create_write_remove_500x4k_wall_ms": rw_res.duration_ms,
            }

        # Category 4 (remaining): Raw TCP stream throughput + PostgreSQL RTT & bulk
        if 4 in categories:
            # Raw TCP 128 MiB bidirectional over mapped loopback ports
            if helper_bin is not None:
                sink_port = alloc_free_port(reserved_ports)
                src_port = alloc_free_port(reserved_ports)
                docker_cmd(context, ["rm", "-f", tcp_container], check=False)
                try:
                    docker_cmd(
                        context,
                        [
                            "run",
                            "-d",
                            "--name",
                            tcp_container,
                            "-p",
                            f"127.0.0.1:{sink_port}:9000",
                            "-p",
                            f"127.0.0.1:{src_port}:9001",
                            "-v",
                            f"{helper_bin.parent}:/bench:ro",
                            ALPINE_IMAGE,
                            "sh",
                            "-c",
                            "/bench/firn-bench-helper tcp-sink -listen :9000 & /bench/firn-bench-helper tcp-source -listen :9001 -bytes 134217728 & wait",
                        ],
                    )
                    # Wait until sink & source are reachable.
                    for port in (sink_port, src_port):
                        deadline = time.monotonic() + 10.0
                        while time.monotonic() < deadline:
                            try:
                                with socket.create_connection(("127.0.0.1", port), timeout=1.0):
                                    pass
                                break
                            except OSError:
                                time.sleep(0.05)

                    total_bytes = 128 * 1024 * 1024
                    chunk = b"T" * (256 * 1024)
                    h2c_mib_s: list[float] = []
                    h2c_ms: list[float] = []
                    for _ in range(3):
                        t0 = time.perf_counter()
                        with socket.create_connection(("127.0.0.1", sink_port), timeout=60.0) as s:
                            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                            sent = 0
                            while sent < total_bytes:
                                s.sendall(chunk)
                                sent += len(chunk)
                            s.shutdown(socket.SHUT_WR)
                            ack = s.recv(128).decode("ascii", "replace").strip()
                            if int(ack) != total_bytes:
                                raise RuntimeError(f"TCP sink ack mismatch: {ack}")
                        elapsed = time.perf_counter() - t0
                        h2c_ms.append(round(elapsed * 1000.0, 2))
                        h2c_mib_s.append(round((total_bytes / (1024 * 1024)) / elapsed, 1))

                    c2h_mib_s: list[float] = []
                    c2h_ms: list[float] = []
                    for _ in range(3):
                        t0 = time.perf_counter()
                        got = 0
                        with socket.create_connection(("127.0.0.1", src_port), timeout=60.0) as s:
                            s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                            while True:
                                data = s.recv(256 * 1024)
                                if not data:
                                    break
                                got += len(data)
                        if got != total_bytes:
                            raise RuntimeError(f"TCP source short read: {got}")
                        elapsed = time.perf_counter() - t0
                        c2h_ms.append(round(elapsed * 1000.0, 2))
                        c2h_mib_s.append(round((total_bytes / (1024 * 1024)) / elapsed, 1))

                    results["cat4_network"].update(
                        {
                            "tcp_128mib_host_to_container_mib_s": round(
                                statistics.median(h2c_mib_s), 1
                            ),
                            "tcp_128mib_host_to_container_ms": round(
                                statistics.median(h2c_ms), 2
                            ),
                            "tcp_128mib_container_to_host_mib_s": round(
                                statistics.median(c2h_mib_s), 1
                            ),
                            "tcp_128mib_container_to_host_ms": round(
                                statistics.median(c2h_ms), 2
                            ),
                        }
                    )
                finally:
                    docker_cmd(context, ["rm", "-f", tcp_container], check=False)

            # Fresh PostgreSQL 18 container for RTT + 19.25 MiB bulk query
            pg_bench_port = alloc_free_port(reserved_ports)
            docker_cmd(context, ["rm", "-f", pg_container], check=False)
            try:
                docker_cmd(
                    context,
                    [
                        "run",
                        "-d",
                        "--name",
                        pg_container,
                        "-e",
                        "POSTGRES_HOST_AUTH_METHOD=trust",
                        "-p",
                        f"127.0.0.1:{pg_bench_port}:5432",
                        POSTGRES_IMAGE,
                        "postgres",
                        "-c",
                        "fsync=off",
                        "-c",
                        "synchronous_commit=off",
                        "-c",
                        "full_page_writes=off",
                    ],
                )
                deadline = time.monotonic() + 30.0
                client: PgWireClient | None = None
                while time.monotonic() < deadline:
                    try:
                        client = PgWireClient("127.0.0.1", pg_bench_port)
                        rows, _ = client.simple_query("SELECT 1")
                        if rows == 1:
                            break
                    except Exception:
                        if client is not None:
                            client.close()
                            client = None
                        time.sleep(0.1)
                if client is None:
                    raise RuntimeError("PostgreSQL benchmark container did not become ready")
                try:
                    client.prepare("s1", "SELECT 1")
                    for _ in range(10):
                        client.execute_prepared("s1")
                    rtts: list[float] = []
                    for _ in range(200):
                        t0 = time.perf_counter()
                        r, _ = client.execute_prepared("s1")
                        if r != 1:
                            raise RuntimeError(f"Expected 1 row from SELECT 1, got {r}")
                        rtts.append((time.perf_counter() - t0) * 1000.0)

                    bulk_sql = (
                        f"SELECT repeat('x', {PG_BULK_ROW_BYTES}) "
                        f"FROM generate_series(1, {PG_BULK_ROWS})"
                    )
                    # Warmup + 3 measured bulk runs
                    client.simple_query(bulk_sql)
                    bulk_ms: list[float] = []
                    bulk_mib_s: list[float] = []
                    expected_bytes = PG_BULK_ROWS * PG_BULK_ROW_BYTES
                    for _ in range(3):
                        t0 = time.perf_counter()
                        nrows, nbytes = client.simple_query(bulk_sql)
                        elapsed = time.perf_counter() - t0
                        if nrows != PG_BULK_ROWS or nbytes != expected_bytes:
                            raise RuntimeError(
                                f"Bulk mismatch: rows={nrows}, bytes={nbytes}"
                            )
                        bulk_ms.append(round(elapsed * 1000.0, 2))
                        bulk_mib_s.append(
                            round((nbytes / (1024 * 1024)) / elapsed, 1)
                        )

                    results["cat4_network"].update(
                        {
                            "postgres_200x_select1_avg_ms": round(
                                statistics.mean(rtts), 3
                            ),
                            "postgres_200x_select1_p50_ms": percentile(rtts, 50.0),
                            "postgres_200x_select1_p95_ms": percentile(rtts, 95.0),
                            "postgres_bulk_mib": round(
                                expected_bytes / (1024 * 1024), 2
                            ),
                            "postgres_bulk_rows": PG_BULK_ROWS,
                            "postgres_bulk_median_ms": round(
                                statistics.median(bulk_ms), 2
                            ),
                            "postgres_bulk_median_mib_s": round(
                                statistics.median(bulk_mib_s), 1
                            ),
                        }
                    )
                finally:
                    client.close()
            finally:
                docker_cmd(context, ["rm", "-f", pg_container], check=False)

        # Category 5: Container Outbound Egress (Unproxied HTTPS inside alpine:3.21)
        if 5 in categories:
            egress_res = docker_cmd(
                context,
                [
                    "run",
                    "--rm",
                    ALPINE_IMAGE,
                    "sh",
                    "-c",
                    f"apk add --no-cache -q curl >/dev/null && curl -sS -o /dev/null -w '%{{http_code}} %{{time_total}} %{{speed_download}} %{{size_download}}\\n' {EGRESS_URL}",
                ],
                timeout=120.0,
            )
            parts = egress_res.stdout.strip().split()
            if len(parts) < 4:
                raise RuntimeError(f"Unexpected curl output: {egress_res.stdout!r}")
            http_code = int(parts[0])
            time_total_s = float(parts[1])
            speed_bps = float(parts[2])
            size_bytes = int(float(parts[3]))
            results["cat5_egress"] = {
                "url": EGRESS_URL,
                "http_code": http_code,
                "curl_time_s": round(time_total_s, 3),
                "speed_mib_s": round(speed_bps / (1024 * 1024), 2),
                "size_bytes": size_bytes,
                "container_wall_ms": egress_res.duration_ms,
                "host_vmenet_count": count_vmenet_interfaces(),
            }

        # Category 6: Docker Image Build (docker build --no-cache)
        if 6 in categories:
            if build_dir.exists():
                shutil.rmtree(build_dir)
            files_root = build_dir / "files"
            payload_1k = b"b" * 1024
            for d_idx in range(25):
                sub = files_root / f"d{d_idx:02d}"
                sub.mkdir(parents=True, exist_ok=True)
                for f_idx in range(20):
                    (sub / f"f{f_idx:02d}.txt").write_bytes(payload_1k)
            (build_dir / "Dockerfile").write_text(
                f"FROM {ALPINE_IMAGE}\n"
                "COPY files /app\n"
                "RUN find /app -type f | wc -l\n",
                encoding="utf-8",
            )
            docker_cmd(context, ["rmi", "-f", build_img], check=False)
            try:
                bld = docker_cmd(
                    context,
                    ["build", "--no-cache", "-t", build_img, str(build_dir)],
                    timeout=180.0,
                )
                results["cat6_docker_build"] = {
                    "files": 500,
                    "no_cache_ms": bld.duration_ms,
                }
            finally:
                docker_cmd(context, ["rmi", "-f", build_img], check=False)

    finally:
        if compose_is_up and compose_file.is_file():
            docker_cmd(
                context,
                ["compose", "-p", compose_project, "-f", str(compose_file), "down", "-v", "--remove-orphans"],
                check=False,
            )
        docker_cmd(context, ["rm", "-f", pg_container, tcp_container], check=False)
        docker_cmd(context, ["volume", "rm", "-f", vol_name], check=False)
        docker_cmd(context, ["rmi", "-f", build_img], check=False)
        if tree_dir.exists():
            shutil.rmtree(tree_dir, ignore_errors=True)
        if build_dir.exists():
            shutil.rmtree(build_dir, ignore_errors=True)

    return results


def parse_guest_uptime_from_serial(serial_log: Path) -> float | None:
    if not serial_log.is_file():
        return None
    text = serial_log.read_text(encoding="utf-8", errors="replace")
    m = re.findall(r"\[firn-init\] ready \(uptime ([0-9.]+)s\)", text)
    return float(m[-1]) if m else None


def redis_ping_tcp(port: int, timeout_s: float = 15.0) -> float:
    t0 = time.perf_counter()
    with socket.create_connection(("127.0.0.1", port), timeout=timeout_s) as s:
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.sendall(b"*1\r\n$4\r\nPING\r\n")
        reply = s.recv(64)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    if not reply.startswith(b"+PONG"):
        raise RuntimeError(f"Unexpected Valkey PING reply: {reply!r}")
    return round(elapsed_ms, 2)


def bench_firn_lifecycle_and_reclaim(
    firn_bin: Path, tmp_dir: Path
) -> dict[str, Any]:
    """Category 7: VM cold boot, idle footprint, 3-stack freeze/reclaim, auto-thaw."""
    out: dict[str, Any] = {}
    if firn_is_running():
        down_res = firn_cli(firn_bin, ["down"], timeout=30.0)
        out["clean_stop_ms"] = down_res.duration_ms
    else:
        # Ensure we still measure a real stop/start cycle if offline initially.
        firn_cli(firn_bin, ["up"], timeout=60.0)
        down_res = firn_cli(firn_bin, ["down"], timeout=30.0)
        out["clean_stop_ms"] = down_res.duration_ms

    up_res = firn_cli(firn_bin, ["up"], timeout=60.0)
    cold_boot_reported_ms: float | None = None
    m = re.search(r"Cold booted Firn VM .* in ([0-9.]+) ms", up_res.stdout)
    if m:
        cold_boot_reported_ms = float(m.group(1))

    serial_log = Path.home() / ".firn" / "serial.log"
    guest_uptime_s = None
    for _ in range(20):
        guest_uptime_s = parse_guest_uptime_from_serial(serial_log)
        if guest_uptime_s is not None:
            break
        time.sleep(0.05)

    out["cold_boot_wall_ms"] = up_res.duration_ms
    out["cold_boot_reported_ms"] = cold_boot_reported_ms
    out["guest_init_ready_uptime_s"] = guest_uptime_s

    # Idle metrics (0 containers)
    time.sleep(2.0)
    pid_file = Path.home() / ".firn" / "run" / "firnd.pid"
    firnd_pid = int(pid_file.read_text(encoding="utf-8").strip())
    idle_status = firn_status_json(firn_bin)
    idle_procs = sample_host_processes(firnd_pid=firnd_pid, interval_sec=5)
    out["idle_zero_containers"] = {
        "firn_host_footprint_mib": round(
            idle_status["hostMemory"]["footprintBytes"] / (1024 * 1024), 1
        ),
        "firn_host_rss_mib": round(
            idle_status["hostMemory"]["rssBytes"] / (1024 * 1024), 1
        ),
        "firnd_footprint_mib": round(
            idle_status["hostMemory"]["daemonFootprintBytes"] / (1024 * 1024), 1
        ),
        "vm_footprint_mib": round(
            idle_status["hostMemory"]["vmFootprintBytes"] / (1024 * 1024), 1
        ),
        "top_firn_cpu_percent": idle_procs["firn"]["cpu_percent"],
        "top_firn_rss_mib": idle_procs["firn"]["rss_mib"],
        "orbstack_helper_cpu_percent": idle_procs["orbstack_helper"]["cpu_percent"],
        "orbstack_helper_rss_mib": idle_procs["orbstack_helper"]["rss_mib"],
    }

    # Multi-stack (3x 2-container stacks)
    ensure_images("firn", [VALKEY_IMAGE, MAILPIT_IMAGE])
    reserved_ports: set[int] = set()
    stacks: list[dict[str, Any]] = []
    for idx in (1, 2, 3):
        proj = f"{RESOURCE_PREFIX}s{idx}"
        valkey_port = alloc_free_port(reserved_ports)
        mailpit_port = alloc_free_port(reserved_ports)
        cfile = tmp_dir / f"{proj}-compose.yml"
        write_compose_file(
            cfile,
            pg_port=0,
            valkey_port=valkey_port,
            mailpit_port=mailpit_port,
            include_postgres=False,
        )
        stacks.append(
            {
                "project": proj,
                "valkey_port": valkey_port,
                "mailpit_port": mailpit_port,
                "compose_file": cfile,
            }
        )

    try:
        for st in stacks:
            docker_cmd(
                "firn",
                [
                    "compose",
                    "-p",
                    st["project"],
                    "-f",
                    str(st["compose_file"]),
                    "up",
                    "-d",
                    "--wait",
                ],
                timeout=120.0,
            )
            redis_ping_tcp(st["valkey_port"])
            wait_http_ok("127.0.0.1", st["mailpit_port"], "/api/v1/info")

        # Wait briefly for HTTPS proxy SAN reload and reaper stats to stabilize.
        ca_cert = Path.home() / ".firn" / "certs" / "ca.crt"
        if ca_cert.is_file():
            for st in stacks:
                wait_https_firn_ok(
                    f"mailpit.{st['project']}.firn.local",
                    8443,
                    "/api/v1/info",
                    ca_cert,
                    timeout_s=10.0,
                )
        time.sleep(1.0)

        active_status = firn_status_json(firn_bin)
        active_disk = firn_disk_json(firn_bin)
        active_procs = sample_host_processes(firnd_pid=firnd_pid, interval_sec=5)
        active_proj_map = {p["project"]: p for p in active_status.get("projects", [])}
        active_ram_bytes = sum(
            active_proj_map[st["project"]]["memoryBytes"]
            for st in stacks
            if st["project"] in active_proj_map
        )

        out["multi_stack_active"] = {
            "stacks": len(stacks),
            "containers": len(stacks) * 2,
            "total_container_ram_mib": round(active_ram_bytes / (1024 * 1024), 2),
            "zram_used_mib": round(
                active_disk["guest"]["zramUsedBytes"] / (1024 * 1024), 2
            ),
            "vm_swap_used_mib": round(
                active_status["vmMemory"]["swapUsedBytes"] / (1024 * 1024), 2
            ),
            "host_footprint_mib": round(
                active_status["hostMemory"]["footprintBytes"] / (1024 * 1024), 1
            ),
            "host_rss_mib": round(
                active_status["hostMemory"]["rssBytes"] / (1024 * 1024), 1
            ),
            "top_firn_cpu_percent": active_procs["firn"]["cpu_percent"],
        }

        freeze_details: list[dict[str, Any]] = []
        for st in stacks:
            fres = firn_cli(
                firn_bin, ["freeze", st["project"], "--reclaim"], timeout=30.0
            )
            fdata = json.loads(fres.stdout)
            before_b = sum(item.get("beforeBytes", 0) for item in fdata.get("reclaim", []))
            after_b = sum(item.get("afterBytes", 0) for item in fdata.get("reclaim", []))
            reclaimed_b = fdata.get("totalReclaimedBytes", max(0, before_b - after_b))
            freeze_details.append(
                {
                    "project": st["project"],
                    "cli_wall_ms": fres.duration_ms,
                    "guest_duration_ms": fdata.get("durationMs"),
                    "before_mib": round(before_b / (1024 * 1024), 2),
                    "after_mib": round(after_b / (1024 * 1024), 2),
                    "reclaimed_mib": round(reclaimed_b / (1024 * 1024), 2),
                    "reclaimed_pct": round(
                        (reclaimed_b * 100.0 / before_b) if before_b else 0.0, 1
                    ),
                }
            )

        # Allow BalloonController 1.5s convergence pass to settle.
        time.sleep(2.0)
        frozen_status = firn_status_json(firn_bin)
        frozen_disk = firn_disk_json(firn_bin)
        frozen_procs = sample_host_processes(firnd_pid=firnd_pid, interval_sec=5)
        frozen_proj_map = {p["project"]: p for p in frozen_status.get("projects", [])}
        frozen_ram_bytes = sum(
            frozen_proj_map[st["project"]]["memoryBytes"]
            for st in stacks
            if st["project"] in frozen_proj_map
        )
        frozen_swap_bytes = sum(
            frozen_proj_map[st["project"]]["swapBytes"]
            for st in stacks
            if st["project"] in frozen_proj_map
        )
        total_before = sum(item["before_mib"] for item in freeze_details)
        total_after = round(frozen_ram_bytes / (1024 * 1024), 2)
        total_reclaimed_pct = round(
            ((active_ram_bytes - frozen_ram_bytes) * 100.0 / active_ram_bytes)
            if active_ram_bytes
            else 0.0,
            1,
        )

        out["multi_stack_frozen"] = {
            "per_stack": freeze_details,
            "total_before_mib": round(active_ram_bytes / (1024 * 1024), 2),
            "total_reclaimed_sum_before_mib": round(total_before, 2),
            "total_after_mib": total_after,
            "reclaimed_pct": total_reclaimed_pct,
            "container_swap_mib": round(frozen_swap_bytes / (1024 * 1024), 2),
            "zram_used_compressed_mib": round(
                frozen_disk["guest"]["zramUsedBytes"] / (1024 * 1024), 2
            ),
            "vm_swap_used_mib": round(
                frozen_status["vmMemory"]["swapUsedBytes"] / (1024 * 1024), 2
            ),
            "host_footprint_mib": round(
                frozen_status["hostMemory"]["footprintBytes"] / (1024 * 1024), 1
            ),
            "host_rss_mib": round(
                frozen_status["hostMemory"]["rssBytes"] / (1024 * 1024), 1
            ),
            "top_firn_cpu_percent": frozen_procs["firn"]["cpu_percent"],
        }

        # Target-First TCP Auto-Thaw on frozen stack 1 (Valkey PING -> +PONG)
        s1 = stacks[0]
        tcp_thaw_ms = redis_ping_tcp(s1["valkey_port"])
        s1_paused = None
        for _ in range(30):
            st_after_tcp = firn_status_json(firn_bin)
            pmap = {p["project"]: p for p in st_after_tcp.get("projects", [])}
            s1_paused = pmap.get(s1["project"], {}).get("pausedCount")
            if s1_paused == 0:
                break
            time.sleep(0.05)

        # HTTPS Auto-Thaw on frozen stack 2 (Mailpit HTTPS :8443)
        s2 = stacks[1]
        https_thaw_ms: float | None = None
        s2_paused = None
        if ca_cert.is_file():
            fqdn2 = f"mailpit.{s2['project']}.firn.local"
            https_thaw_ms = wait_https_firn_ok(
                fqdn2, 8443, "/", ca_cert, timeout_s=10.0
            )
            for _ in range(30):
                st_after_https = firn_status_json(firn_bin)
                pmap = {p["project"]: p for p in st_after_https.get("projects", [])}
                s2_paused = pmap.get(s2["project"], {}).get("pausedCount")
                if s2_paused == 0:
                    break
                time.sleep(0.05)

        # Run `firn bench --project <s1> --compare-orbstack` on thawed s1
        bench_res = firn_cli(
            firn_bin,
            ["bench", "--project", s1["project"], "--compare-orbstack"],
            timeout=30.0,
        )
        bench_json = json.loads(bench_res.stdout)

        out["autothaw"] = {
            "tcp_valkey_ping_ms": tcp_thaw_ms,
            "tcp_target_project": s1["project"],
            "tcp_paused_count_after": s1_paused,
            "https_mailpit_ms": https_thaw_ms,
            "https_target_project": s2["project"],
            "https_paused_count_after": s2_paused,
        }
        out["firn_bench_snapshot"] = bench_json
    finally:
        for st in stacks:
            docker_cmd(
                "firn",
                [
                    "compose",
                    "-p",
                    st["project"],
                    "-f",
                    str(st["compose_file"]),
                    "down",
                    "-v",
                    "--remove-orphans",
                ],
                check=False,
            )
            if st["compose_file"].exists():
                st["compose_file"].unlink(missing_ok=True)

    return out


def format_human_summary(report: dict[str, Any]) -> str:
    lines: list[str] = []
    meta = report["metadata"]
    lines.append(
        f"Firn Benchmark Report | Host: {meta['machine']} ({meta['ncpu']} CPUs, "
        f"{meta['ram_gib']} GiB RAM, macOS {meta['macos_version']}) | "
        f"Docker {meta['docker_client_version']} / Compose {meta['compose_version']}"
    )
    lines.append("=" * 96)

    ctxs = report.get("contexts", {})
    names = list(ctxs.keys())
    if names:
        header = f"{'Metric':<48} | " + " | ".join(f"{n:<20}" for n in names)
        lines.append(header)
        lines.append("-" * len(header))

        def row(label: str, getter) -> None:
            vals = []
            for n in names:
                try:
                    v = getter(ctxs[n])
                except Exception:
                    v = "—"
                vals.append(f"{str(v):<20}")
            lines.append(f"{label:<48} | " + " | ".join(vals))

        row("Cat 1: docker version (5x median ms)", lambda c: f"{c['cat1_lifecycle']['docker_version_median_ms']} ms")
        row("Cat 1: alpine:3.21 true (5x median ms)", lambda c: f"{c['cat1_lifecycle']['alpine_run_median_ms']} ms")
        row("Cat 1: postgres:18 true (5x median ms)", lambda c: f"{c['cat1_lifecycle']['postgres_entrypoint_true_median_ms']} ms")
        row("Cat 1: 3-svc Compose up -d --wait (ms)", lambda c: f"{c['cat1_lifecycle']['compose_up_wait_ms']} ms")
        row("Cat 1: 3-svc Compose down -v (ms)", lambda c: f"{c['cat1_lifecycle']['compose_down_ms']} ms")
        row("Cat 2: Volume 256 MiB seq write", lambda c: f"{c['cat2_volume_io']['seq_write_256mib_mib_s']} MiB/s ({c['cat2_volume_io']['seq_write_256mib_ms']} ms)")
        row("Cat 2: Volume 256 MiB seq read", lambda c: f"{c['cat2_volume_io']['seq_read_256mib_mib_s']} MiB/s ({c['cat2_volume_io']['seq_read_256mib_ms']} ms)")
        row("Cat 2: Volume 1,000x4K fsync+unlink", lambda c: f"{c['cat2_volume_io']['small_file_burst_1000x4k_fsync_unlink']['total_ms']} ms ({c['cat2_volume_io']['small_file_burst_1000x4k_fsync_unlink']['ops_per_sec']} ops/s)")
        row("Cat 3: VirtioFS 1,000-file walk (cold/med)", lambda c: f"{c['cat3_virtiofs']['tree_walk_1000_files_cold_ms']} / {c['cat3_virtiofs']['tree_walk_1000_files_median_ms']} ms")
        row("Cat 3: VirtioFS read 1,000 files", lambda c: f"{c['cat3_virtiofs']['read_1000_files_in_container_ms']} ms")
        row("Cat 3: VirtioFS create+rm 500x4K files", lambda c: f"{c['cat3_virtiofs']['create_write_remove_500x4k_in_container_ms']} ms")
        row("Cat 4: TCP 128 MiB Host->Container", lambda c: f"{c['cat4_network']['tcp_128mib_host_to_container_mib_s']} MiB/s ({c['cat4_network']['tcp_128mib_host_to_container_ms']} ms)")
        row("Cat 4: TCP 128 MiB Container->Host", lambda c: f"{c['cat4_network']['tcp_128mib_container_to_host_mib_s']} MiB/s ({c['cat4_network']['tcp_128mib_container_to_host_ms']} ms)")
        row("Cat 4: HTTP keep-alive 500 req (c=16)", lambda c: f"{c['cat4_network']['http_keepalive']['rps']} req/s (p50 {c['cat4_network']['http_keepalive']['p50_ms']} ms)")
        row("Cat 4: HTTP conn/req 500 req (c=16)", lambda c: f"{c['cat4_network']['http_conn_per_req']['rps']} req/s (p50 {c['cat4_network']['http_conn_per_req']['p50_ms']} ms)")
        row("Cat 4: PG 200x SELECT 1 RTT (avg/p50)", lambda c: f"{c['cat4_network']['postgres_200x_select1_avg_ms']} / {c['cat4_network']['postgres_200x_select1_p50_ms']} ms")
        row("Cat 4: PG 19.25 MiB bulk query", lambda c: f"{c['cat4_network']['postgres_bulk_median_mib_s']} MiB/s ({c['cat4_network']['postgres_bulk_median_ms']} ms)")
        row("Cat 5: Container unproxied HTTPS egress", lambda c: f"HTTP {c['cat5_egress']['http_code']} ({c['cat5_egress']['speed_mib_s']} MiB/s, {c['cat5_egress']['curl_time_s']}s)")
        row("Cat 6: docker build --no-cache (500 files)", lambda c: f"{c['cat6_docker_build']['no_cache_ms']} ms")

    cat7 = report.get("cat7_firn_lifecycle")
    if cat7:
        lines.append("")
        lines.append("Cat 7: Firn VM Lifecycle, Multi-Stack Reclaim & Auto-Thaw")
        lines.append("-" * 96)
        lines.append(f"Clean stop (`firn down`): {cat7['clean_stop_ms']} ms")
        lines.append(
            f"Cold boot (`firn up` wall / guest `[firn-init] ready`): "
            f"{cat7['cold_boot_wall_ms']} ms / {cat7['guest_init_ready_uptime_s']}s"
        )
        idle = cat7["idle_zero_containers"]
        lines.append(
            f"Idle (0 containers): Firn CPU {idle['top_firn_cpu_percent']}%, "
            f"footprint {idle['firn_host_footprint_mib']} MiB (RSS {idle['firn_host_rss_mib']} MiB) | "
            f"OrbStack Helper CPU {idle['orbstack_helper_cpu_percent']}%, RSS {idle['orbstack_helper_rss_mib']} MiB"
        )
        act = cat7["multi_stack_active"]
        frz = cat7["multi_stack_frozen"]
        lines.append(
            f"3x 2-container stacks active: RAM {act['total_container_ram_mib']} MiB, "
            f"zram0 {act['zram_used_mib']} MiB, host footprint {act['host_footprint_mib']} MiB"
        )
        lines.append(
            f"3x stacks frozen (`--reclaim`): RAM {frz['total_before_mib']} -> {frz['total_after_mib']} MiB "
            f"({frz['reclaimed_pct']}% reclaimed), zram0 compressed {frz['zram_used_compressed_mib']} MiB, "
            f"host footprint {frz['host_footprint_mib']} MiB"
        )
        th = cat7["autothaw"]
        lines.append(
            f"Auto-Thaw: TCP Valkey PING {th['tcp_valkey_ping_ms']} ms (paused={th['tcp_paused_count_after']}) | "
            f"HTTPS *.firn.local:8443 {th['https_mailpit_ms']} ms (paused={th['https_paused_count_after']})"
        )
    return "\n".join(lines)


def collect_metadata() -> dict[str, Any]:
    sysctl_out = run_cmd(
        ["sysctl", "-n", "machdep.cpu.brand_string", "hw.ncpu", "hw.memsize"]
    ).stdout.splitlines()
    macos_ver = run_cmd(["sw_vers", "-productVersion"]).stdout.strip()
    docker_ver = run_cmd(["docker", "version", "--format", "{{.Client.Version}}"]).stdout.strip()
    compose_ver = run_cmd(["docker", "compose", "version", "--short"]).stdout.strip()
    mem_bytes = int(sysctl_out[2]) if len(sysctl_out) > 2 else 0
    return {
        "machine": sysctl_out[0] if len(sysctl_out) > 0 else platform.machine(),
        "ncpu": int(sysctl_out[1]) if len(sysctl_out) > 1 else os.cpu_count(),
        "ram_gib": round(mem_bytes / (1024**3), 1),
        "arch": platform.machine(),
        "macos_version": macos_ver,
        "docker_client_version": docker_ver,
        "compose_version": compose_ver,
        "vmenet_count": count_vmenet_interfaces(),
        "default_docker_context": run_cmd(["docker", "context", "show"]).stdout.strip(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Reproducible apples-to-apples benchmark suite for Firn and OrbStack."
    )
    parser.add_argument(
        "--compare",
        action="store_true",
        help="Run side-by-side comparison across firn and orbstack (default when both exist).",
    )
    parser.add_argument(
        "--contexts",
        default="",
        help="Comma-separated Docker contexts to benchmark (default: firn,orbstack).",
    )
    parser.add_argument(
        "--categories",
        default="1,2,3,4,5,6,7",
        help="Comma-separated benchmark categories 1..7 to run (default: 1,2,3,4,5,6,7).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print structured JSON output to stdout instead of a formatted table.",
    )
    parser.add_argument(
        "--json-out",
        default="",
        help="Optional file path to also save the JSON report.",
    )
    parser.add_argument(
        "--firn-bin",
        default="",
        help="Path to the firn CLI binary (auto-detected under ./build/firn or PATH).",
    )
    parser.add_argument(
        "--keep-running",
        action="store_true",
        help="Leave Firn running after benchmarks even if it was offline beforehand.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    tmp_dir = Path.home() / ".firn" / "bench-tmp"
    categories = {int(c.strip()) for c in args.categories.split(",") if c.strip()}

    available_contexts = set(
        run_cmd(["docker", "context", "ls", "--format", "{{.Name}}"]).stdout.split()
    )
    if args.contexts:
        contexts = [c.strip() for c in args.contexts.split(",") if c.strip()]
    elif args.compare or ("firn" in available_contexts and "orbstack" in available_contexts):
        contexts = [c for c in ("firn", "orbstack") if c in available_contexts]
    else:
        contexts = [run_cmd(["docker", "context", "show"]).stdout.strip()]

    for ctx in contexts:
        if ctx not in available_contexts:
            raise SystemExit(f"Requested Docker context '{ctx}' does not exist.")

    default_ctx_before = run_cmd(["docker", "context", "show"]).stdout.strip()
    firn_bin = detect_firn_bin(repo_root, args.firn_bin, "firn")
    firn_was_running = firn_is_running()
    started_firn_here = False

    tmp_dir.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "metadata": collect_metadata(),
        "contexts": {},
    }

    try:
        if "firn" in contexts and not firn_is_running():
            if firn_bin is None:
                raise RuntimeError(
                    "Firn context requested while daemon is offline and `firn` binary was not found."
                )
            print("[bench] Starting Firn VM via `firn up`...", file=sys.stderr)
            firn_cli(firn_bin, ["up"], timeout=60.0)
            started_firn_here = True

        arch = docker_cmd(contexts[0], ["version", "--format", "{{.Server.Arch}}"]).stdout.strip()
        helper_bin = build_helper_binary(repo_root, tmp_dir, arch)

        for ctx in contexts:
            print(f"[bench] Benchmarking context '{ctx}'...", file=sys.stderr)
            report["contexts"][ctx] = bench_context(
                ctx, categories, tmp_dir, helper_bin, firn_bin
            )

        if 7 in categories and "firn" in contexts:
            if firn_bin is None:
                raise RuntimeError("Category 7 requires `firn` binary (./build/firn).")
            print("[bench] Running Category 7 (Firn lifecycle, reclaim, auto-thaw)...", file=sys.stderr)
            report["cat7_firn_lifecycle"] = bench_firn_lifecycle_and_reclaim(
                firn_bin, tmp_dir
            )

    finally:
        # Clean up ~/.firn/bench-tmp and restore firn daemon state if we started it.
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir, ignore_errors=True)
        if not args.keep_running and not firn_was_running and firn_is_running() and firn_bin is not None:
            print("[bench] Stopping Firn VM cleanly via `firn down`...", file=sys.stderr)
            run_cmd([str(firn_bin), "down"], timeout=30.0, check=False)
        elif started_firn_here and not args.keep_running and firn_is_running() and firn_bin is not None:
            run_cmd([str(firn_bin), "down"], timeout=30.0, check=False)

        default_ctx_after = run_cmd(["docker", "context", "show"]).stdout.strip()
        if default_ctx_after != default_ctx_before:
            run_cmd(["docker", "context", "use", default_ctx_before], check=False)

    if args.json_out:
        out_path = Path(args.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(format_human_summary(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
