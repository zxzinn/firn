#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIRN_BIN="${FIRN_BIN:-$ROOT_DIR/build/firn}"
if [ ! -x "$FIRN_BIN" ]; then
  FIRN_BIN="$(command -v firn)"
fi
if [ -z "${FIRN_BIN:-}" ] || [ ! -x "$FIRN_BIN" ]; then
  echo "[e2e] firn CLI binary not found (run 'make build' first)" >&2
  exit 1
fi

if go version >/dev/null 2>&1; then
  GO_CMD=(go)
else
  GO_CMD=(mise exec go@1.27.4 -- go)
fi

WORK_DIR="$(mktemp -d "$HOME/.firn-e2e.XXXXXX")"
HOST_SRV_PID=""
INOTIFY_CID=""
K8S_WAS_CLEANED=0

cleanup() {
  local rc=$?
  set +e
  if [ -n "$HOST_SRV_PID" ]; then
    kill "$HOST_SRV_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$INOTIFY_CID" ]; then
    docker --context firn rm -f "$INOTIFY_CID" >/dev/null 2>&1 || true
  fi
  docker --context firn rm -f firn-machine-e2ebox firn-machine-e2ecopy >/dev/null 2>&1 || true
  docker --context firn volume rm -f firn-machine-e2ebox-home firn-machine-e2ecopy-home >/dev/null 2>&1 || true
  docker --context firn rmi -f e2e-amd64:v06 hello-k8s:v06 >/dev/null 2>&1 || true
  "$FIRN_BIN" buildx remove >/dev/null 2>&1 || true
  if [ "$K8S_WAS_CLEANED" = "0" ]; then
    "$FIRN_BIN" shell -- /var/lib/firn/k3s/bin/k3s kubectl delete deployment/hello-web service/hello-web --ignore-not-found >/dev/null 2>&1 || true
    "$FIRN_BIN" k8s disable >/dev/null 2>&1 || true
  fi
  "$FIRN_BIN" down >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'echo "[e2e] FAILED at line $LINENO (cmd: $BASH_COMMAND)" >&2' ERR

step() {
  echo ""
  echo "=== [e2e] $1 ==="
}

step "1. Boot Firn VM & verify capabilities"
"$FIRN_BIN" down >/dev/null 2>&1 || true
"$FIRN_BIN" up
STATUS_JSON="$("$FIRN_BIN" status --json)"
python3 - "$STATUS_JSON" <<'PYEOF'
import json, sys
s = json.loads(sys.argv[1])
caps = s.get("capabilities", {})
assert caps.get("firnfsActive") is True, f"expected firnfsActive=true, got {caps}"
assert caps.get("fastVirtioNet") is True, f"expected fastVirtioNet=true, got {caps}"
print("[e2e] status ok: firnfsActive=true fastVirtioNet=true")
PYEOF

step "2. Verify host.docker.internal & host.firn.internal -> 10.89.0.1 reachability"
python3 - "$WORK_DIR/host_port.txt" <<'PYEOF' &
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys
from pathlib import Path

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"firn-host-ok")
    def log_message(self, *args):
        pass

srv = HTTPServer(("0.0.0.0", 0), H)
Path(sys.argv[1]).write_text(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
HOST_SRV_PID=$!

for _ in $(seq 1 30); do
  if [ -s "$WORK_DIR/host_port.txt" ]; then break; fi
  sleep 0.1
done
HOST_PORT="$(cat "$WORK_DIR/host_port.txt")"
test -n "$HOST_PORT"

docker --context firn run --rm alpine:3.21 sh -eu -c "
  for h in host.docker.internal host.firn.internal; do
    ip=\$(getent hosts \"\$h\" | awk '{print \$1}' | head -n1)
    echo \"\$h -> \$ip\"
    test \"\$ip\" = '10.89.0.1'
  done
  body=\$(wget -qO- \"http://host.docker.internal:$HOST_PORT/\")
  test \"\$body\" = 'firn-host-ok'
  body2=\$(wget -qO- \"http://host.firn.internal:$HOST_PORT/\")
  test \"\$body2\" = 'firn-host-ok'
"
kill "$HOST_SRV_PID" >/dev/null 2>&1 || true
wait "$HOST_SRV_PID" >/dev/null 2>&1 || true
HOST_SRV_PID=""

step "3. Verify firnfs v3 synthetic inotify events + byte integrity"
WATCH_DIR="$WORK_DIR/hmr"
mkdir -p "$WATCH_DIR"
printf 'initial-payload-001\n' > "$WATCH_DIR/existing.txt"

cat > "$WORK_DIR/inotify_watch.go" <<'GOEOF'
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

func main() {
	if len(os.Args) < 2 {
		os.Exit(2)
	}
	watchDir := os.Args[1]

	fd, err := syscall.InotifyInit()
	if err != nil {
		fmt.Fprintf(os.Stderr, "inotify_init: %v\n", err)
		os.Exit(1)
	}
	defer syscall.Close(fd)

	mask := uint32(syscall.IN_CREATE | syscall.IN_MODIFY | syscall.IN_DELETE | syscall.IN_MOVED_TO | syscall.IN_MOVED_FROM | syscall.IN_CLOSE_WRITE)
	if _, err := syscall.InotifyAddWatch(fd, watchDir, mask); err != nil {
		fmt.Fprintf(os.Stderr, "inotify_add_watch: %v\n", err)
		os.Exit(1)
	}
	// Prime dentry/page cache on pre-existing file inside container VFS.
	_, _ = os.ReadFile(filepath.Join(watchDir, "existing.txt"))
	fmt.Println("READY")

	buf := make([]byte, 32768)
	for {
		n, rerr := syscall.Read(fd, buf)
		if rerr != nil {
			os.Exit(1)
		}
		var off int
		for off+syscall.SizeofInotifyEvent <= n {
			ev := (*syscall.InotifyEvent)(unsafe.Pointer(&buf[off]))
			nameStart := off + syscall.SizeofInotifyEvent
			nameEnd := nameStart + int(ev.Len)
			var name string
			if ev.Len > 0 && nameEnd <= n {
				name = strings.TrimRight(string(buf[nameStart:nameEnd]), "\x00")
			}
			var tags []string
			if ev.Mask&syscall.IN_CREATE != 0 {
				tags = append(tags, "CREATE")
			}
			if ev.Mask&syscall.IN_MODIFY != 0 {
				tags = append(tags, "MODIFY")
			}
			if ev.Mask&syscall.IN_CLOSE_WRITE != 0 {
				tags = append(tags, "CLOSE_WRITE")
			}
			if ev.Mask&syscall.IN_DELETE != 0 {
				tags = append(tags, "DELETE")
			}
			if ev.Mask&syscall.IN_ISDIR != 0 {
				tags = append(tags, "ISDIR")
			}
			if len(tags) > 0 && name != "" {
				fmt.Printf("%s:%s\n", strings.Join(tags, ","), name)
			}
			off = nameEnd
		}
	}
}
GOEOF
printf 'module e2e\ngo 1.21\n' > "$WORK_DIR/go.mod"
(
  cd "$WORK_DIR"
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 "${GO_CMD[@]}" build -o "$WORK_DIR/inotify-watch" inotify_watch.go
)

INOTIFY_LOG="$WORK_DIR/events.log"
INOTIFY_CID="firn-e2e-inotify-$$"
docker --context firn run -d --name "$INOTIFY_CID" -v "$WORK_DIR:$WORK_DIR" alpine:3.21 \
  "$WORK_DIR/inotify-watch" "$WATCH_DIR" >/dev/null

WATCH_READY=0
for _ in $(seq 1 50); do
  if docker --context firn logs "$INOTIFY_CID" 2>&1 | grep -q "^READY$"; then
    WATCH_READY=1
    break
  fi
  sleep 0.1
done
if [ "$WATCH_READY" != "1" ]; then
  echo "[e2e] inotify-watch did not become ready; container logs:" >&2
  docker --context firn logs "$INOTIFY_CID" >&2 || true
  exit 1
fi

# 3a. Modify pre-existing cached file on host
printf 'updated-existing-payload-002\n' > "$WATCH_DIR/existing.txt"
EXISTING_HOST_SHA="$(shasum -a 256 "$WATCH_DIR/existing.txt" | awk '{print $1}')"

# 3b. Create directory and new file on host, then modify and delete
mkdir -p "$WATCH_DIR/sub"
printf 'brand-new-file-v1\n' > "$WATCH_DIR/new.txt"
sleep 0.4
printf 'brand-new-file-v2-edited\n' > "$WATCH_DIR/new.txt"
NEW_HOST_SHA="$(shasum -a 256 "$WATCH_DIR/new.txt" | awk '{print $1}')"

sleep 0.8
EXISTING_GUEST_SHA="$(docker --context firn exec "$INOTIFY_CID" sha256sum "$WATCH_DIR/existing.txt" | awk '{print $1}')"
NEW_GUEST_SHA="$(docker --context firn exec "$INOTIFY_CID" sha256sum "$WATCH_DIR/new.txt" | awk '{print $1}')"
echo "[e2e] sha256 existing host=$EXISTING_HOST_SHA guest=$EXISTING_GUEST_SHA"
echo "[e2e] sha256 new      host=$NEW_HOST_SHA guest=$NEW_GUEST_SHA"
test "$EXISTING_HOST_SHA" = "$EXISTING_GUEST_SHA"
test "$NEW_HOST_SHA" = "$NEW_GUEST_SHA"

rm -f "$WATCH_DIR/new.txt"
rmdir "$WATCH_DIR/sub"

# Wait up to 3s for all synthetic kernel inotify events
for _ in $(seq 1 30); do
  docker --context firn logs "$INOTIFY_CID" > "$INOTIFY_LOG" 2>&1 || true
  if grep -q "MODIFY.*:existing.txt" "$INOTIFY_LOG" 2>/dev/null \
     && grep -q "CREATE.*:new.txt" "$INOTIFY_LOG" 2>/dev/null \
     && grep -q "MODIFY.*:new.txt" "$INOTIFY_LOG" 2>/dev/null \
     && grep -q "DELETE.*:new.txt" "$INOTIFY_LOG" 2>/dev/null \
     && grep -q "CREATE.*ISDIR:sub" "$INOTIFY_LOG" 2>/dev/null \
     && grep -q "DELETE.*ISDIR:sub" "$INOTIFY_LOG" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

docker --context firn logs "$INOTIFY_CID" > "$INOTIFY_LOG" 2>&1 || true
cat "$INOTIFY_LOG"
grep -q "MODIFY.*:existing.txt" "$INOTIFY_LOG"
grep -q "CREATE.*:new.txt" "$INOTIFY_LOG"
grep -q "MODIFY.*:new.txt" "$INOTIFY_LOG"
grep -q "DELETE.*:new.txt" "$INOTIFY_LOG"
grep -q "CREATE.*ISDIR:sub" "$INOTIFY_LOG"
grep -q "DELETE.*ISDIR:sub" "$INOTIFY_LOG"
docker --context firn rm -f "$INOTIFY_CID" >/dev/null
INOTIFY_CID=""
echo "[e2e] firnfs v3 inotify + byte integrity passed!"

step "4. Verify hibernate + resume + post-resume balloon"
"$FIRN_BIN" hibernate --json
HIB_STATUS="$("$FIRN_BIN" status --json)"
python3 - "$HIB_STATUS" <<'PYEOF'
import json, sys
s = json.loads(sys.argv[1])
assert s.get("hibernated") is True, f"expected hibernated=true, got {s}"
print("[e2e] hibernate ok")
PYEOF
"$FIRN_BIN" resume --json
sleep 3
RESUMED_STATUS="$("$FIRN_BIN" status --json)"
python3 - "$RESUMED_STATUS" <<'PYEOF'
import json, sys
s = json.loads(sys.argv[1])
assert s.get("hibernated") is False, f"expected hibernated=false after resume, got {s}"
b = s.get("balloon", {})
assert b.get("targetBytes", 1<<40) < b.get("maxBytes", 0), f"expected post-resume balloon target < max, got {b}"
clients = (s.get("hostnet") or {}).get("firnfsClients", 0)
assert clients >= 1, f"expected firnfsClients >= 1 after resume, got {s.get('hostnet')}"
print(f"[e2e] resume ok: balloonTarget={b.get('targetBytes')} max={b.get('maxBytes')} firnfsClients={clients}")
PYEOF

step "5. Verify Kubernetes (k3s) zero-config dev loop"
"$FIRN_BIN" k8s enable --no-kubeconfig
mkdir -p "$WORK_DIR/k8s-app"
printf 'module k8sapp\ngo 1.21\n' > "$WORK_DIR/k8s-app/go.mod"
cat > "$WORK_DIR/k8s-app/server.go" <<'GOEOF'
package main
import ("fmt"; "net/http")
func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "k8s-firn-v06-ok")
	})
	_ = http.ListenAndServe(":8080", nil)
}
GOEOF
(
  cd "$WORK_DIR/k8s-app"
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 "${GO_CMD[@]}" build -o "$WORK_DIR/k8s-app/server" server.go
)
cat > "$WORK_DIR/k8s-app/Dockerfile" <<'DEOF'
FROM alpine:3.21
COPY server /usr/local/bin/server
EXPOSE 8080
CMD ["/usr/local/bin/server"]
DEOF
docker --context firn build -t hello-k8s:v06 "$WORK_DIR/k8s-app" >/dev/null
"$FIRN_BIN" k8s load hello-k8s:v06

cat > "$WORK_DIR/hello-k8s.yaml" <<'K8SEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-web
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-web
  template:
    metadata:
      labels:
        app: hello-web
    spec:
      containers:
        - name: web
          image: docker.io/library/hello-k8s:v06
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: hello-web
  namespace: default
spec:
  selector:
    app: hello-web
  ports:
    - name: http
      port: 80
      targetPort: 8080
K8SEOF

if command -v kubectl >/dev/null 2>&1; then
  "$FIRN_BIN" k8s kubeconfig > "$WORK_DIR/kubeconfig.yaml"
  kubectl --kubeconfig "$WORK_DIR/kubeconfig.yaml" apply -f "$WORK_DIR/hello-k8s.yaml"
  kubectl --kubeconfig "$WORK_DIR/kubeconfig.yaml" rollout status deployment/hello-web --timeout=90s
else
  "$FIRN_BIN" shell -- /var/lib/firn/k3s/bin/k3s kubectl apply -f "$WORK_DIR/hello-k8s.yaml"
  "$FIRN_BIN" shell -- /var/lib/firn/k3s/bin/k3s kubectl rollout status deployment/hello-web --timeout=90s
fi
SVC_FOUND=0
for _ in $(seq 1 20); do
  if "$FIRN_BIN" k8s services --json | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(s['name']=='hello-web' for s in d.get('services',[])) else 1)"; then
    SVC_FOUND=1
    break
  fi
  sleep 1
done
test "$SVC_FOUND" = "1"

# Verify LocalDNS + HTTPS ingress proxy reaches k3s ClusterIP -> Pod
dig @127.0.0.1 -p 53535 hello-web.default.k8s.firn.local +short | grep -qx "127.0.0.1"
K8S_BODY=""
for _ in $(seq 1 15); do
  if K8S_BODY="$(curl -ksS --max-time 3 --resolve "hello-web.default.k8s.firn.local:8443:127.0.0.1" "https://hello-web.default.k8s.firn.local:8443/")" && [ "$K8S_BODY" = "k8s-firn-v06-ok" ]; then
    break
  fi
  sleep 1
done
echo "[e2e] k8s response: $K8S_BODY"
test "$K8S_BODY" = "k8s-firn-v06-ok"

"$FIRN_BIN" shell -- /var/lib/firn/k3s/bin/k3s kubectl delete deployment/hello-web service/hello-web --ignore-not-found >/dev/null
"$FIRN_BIN" k8s disable >/dev/null
K8S_WAS_CLEANED=1

step "6. Verify Linux Machine create + clone + home volume preservation"
"$FIRN_BIN" machine create e2ebox --distro alpine
"$FIRN_BIN" machine shell e2ebox -- sh -c "echo clone-marker-v06 > /root/marker.txt"
"$FIRN_BIN" machine clone e2ebox e2ecopy
CLONE_OUT="$("$FIRN_BIN" machine shell e2ecopy -- cat /root/marker.txt | tr -d '\r\n')"
test "$CLONE_OUT" = "clone-marker-v06"
"$FIRN_BIN" machine delete e2ebox
"$FIRN_BIN" machine delete e2ecopy

step "7. Verify Buildx multi-arch setup + Rosetta linux/amd64"
"$FIRN_BIN" buildx setup
mkdir -p "$WORK_DIR/amd64-test"
cat > "$WORK_DIR/amd64-test/Dockerfile" <<'DEOF'
FROM alpine:3.21
CMD ["uname", "-m"]
DEOF
docker --context firn buildx build --platform linux/amd64 --load -t e2e-amd64:v06 "$WORK_DIR/amd64-test" >/dev/null
ARCH_OUT="$(docker --context firn run --rm --platform linux/amd64 e2e-amd64:v06 | tr -d '\r\n')"
echo "[e2e] amd64 container uname -m: $ARCH_OUT"
test "$ARCH_OUT" = "x86_64"
docker --context firn rmi -f e2e-amd64:v06 >/dev/null
"$FIRN_BIN" buildx remove

step "8. Verify disk usage DF breakdown, prune, trim, mount & socket"
DISK_JSON="$("$FIRN_BIN" disk usage --json)"
python3 - "$DISK_JSON" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
g = d.get("guest", {})
assert "dockerImagesBytes" in g, f"missing dockerImagesBytes in {d}"
print(f"[e2e] disk df ok: hostAlloc={d.get('hostAllocatedBytes')} dockerImages={g.get('dockerImagesBytes')}")
PYEOF
"$FIRN_BIN" disk prune --json >/dev/null
"$FIRN_BIN" disk trim --json >/dev/null
"$FIRN_BIN" mount list
"$FIRN_BIN" socket status

step "9. Shutdown cleanly"
"$FIRN_BIN" down
echo ""
echo "[e2e] ALL E2E CHECKS PASSED!"
