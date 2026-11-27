package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type guestConfigFile struct {
	IdleSeconds    int      `json:"idleSeconds"`
	PollSeconds    int      `json:"pollSeconds"`
	Domain         string   `json:"domain"`
	ExemptProjects []string `json:"exemptProjects"`
}

func loadGuestConfig(path string) guestConfigFile {
	cfg := guestConfigFile{
		IdleSeconds:    900,
		PollSeconds:    15,
		Domain:         "firn.local",
		ExemptProjects: []string{},
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return cfg
	}
	_ = json.Unmarshal(raw, &cfg)
	if cfg.Domain == "" {
		cfg.Domain = "firn.local"
	}
	if cfg.PollSeconds < 5 {
		cfg.PollSeconds = 5
	}
	return cfg
}

func writeJSON(w http.ResponseWriter, code int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(payload)
}

func buildControlMux(engine *ReaperEngine, relay *ProxyAndDNSRelay) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, err := engine.docker.ListContainers()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		st, err := engine.Status(time.Now())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, st)
	})

	mux.HandleFunc("/ports", func(w http.ResponseWriter, r *http.Request) {
		ports, _, err := engine.CachedPortsAndDNS(time.Now())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ports": ports})
	})

	mux.HandleFunc("/dns", func(w http.ResponseWriter, r *http.Request) {
		_, records, err := engine.CachedPortsAndDNS(time.Now())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"domain": engine.domain, "records": records})
	})

	mux.HandleFunc("/topology", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		since, _ := strconv.ParseUint(q.Get("since"), 10, 64)
		waitSec := 0
		if raw := q.Get("wait"); raw != "" {
			waitSec, _ = strconv.Atoi(raw)
		}
		if waitSec < 0 {
			waitSec = 0
		}
		if waitSec > 15 {
			waitSec = 15
		}
		topo, err := engine.WaitTopology(r.Context(), since, time.Duration(waitSec)*time.Second)
		if err != nil && r.Context().Err() == nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		if r.Context().Err() != nil {
			return
		}
		writeJSON(w, http.StatusOK, topo)
	})

	mux.HandleFunc("/drop-caches", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		if err := engine.DropPageCaches(); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "vmMemory": ParseMeminfo(engine.meminfoPath)})
	})

	mux.HandleFunc("/proxy-config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			writeJSON(w, http.StatusOK, relay.Config())
			return
		}
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST/GET required"})
			return
		}
		var cfg ProxyConfig
		if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		relay.SetConfig(cfg)
		writeJSON(w, http.StatusOK, relay.Config())
	})

	mux.HandleFunc("/freeze/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		proj, _ := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/freeze/"))
		q := r.URL.Query()
		reclaim := q.Get("reclaim") == "1" || q.Get("reclaim") == "true"
		dropCaches := q.Get("dropCaches") == "1" || q.Get("dropCaches") == "true" || reclaim
		res, err := engine.FreezeProject(proj, reclaim, dropCaches)
		if err != nil {
			code := http.StatusInternalServerError
			if strings.HasPrefix(err.Error(), "unknown project") {
				code = http.StatusNotFound
			}
			writeJSON(w, code, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("/thaw/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		proj, _ := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/thaw/"))
		target := r.URL.Query().Get("target")
		res, err := engine.ThawProjectTarget(proj, target)
		if err != nil {
			code := http.StatusInternalServerError
			if strings.HasPrefix(err.Error(), "unknown project") {
				code = http.StatusNotFound
			}
			writeJSON(w, code, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		var cfg guestConfigFile
		if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		engine.ApplyConfig(cfg.IdleSeconds, cfg.Domain, cfg.ExemptProjects)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})

	mux.HandleFunc("/disk/usage", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, engine.DiskUsage())
	})

	mux.HandleFunc("/disk/trim", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		summary, err := engine.TrimDisk()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error(), "summary": summary})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "summary": summary, "disk": engine.DiskUsage()})
	})

	mux.HandleFunc("/poweroff", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		go func() {
			time.Sleep(25 * time.Millisecond)
			_ = syscall.Kill(1, syscall.SIGTERM)
		}()
	})

	mux.HandleFunc("/reclaim", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		dropCaches := r.URL.Query().Get("dropCaches") != "0"
		res, err := engine.Reclaim("", dropCaches)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("/reclaim/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
			return
		}
		proj, _ := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/reclaim/"))
		dropCaches := r.URL.Query().Get("dropCaches") != "0"
		res, err := engine.Reclaim(proj, dropCaches)
		if err != nil {
			code := http.StatusInternalServerError
			if strings.HasPrefix(err.Error(), "unknown project") {
				code = http.StatusNotFound
			}
			writeJSON(w, code, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	return mux
}

func main() {
	dockerSock := flag.String("docker-socket", "/var/run/docker.sock", "Docker unix socket path")
	debugSock := flag.String("socket", "/run/firn/reaper.sock", "Local unix debug socket path")
	configPath := flag.String("config", "/etc/firn/reaper.json", "Reaper config path")
	flag.Parse()

	cfg := loadGuestConfig(*configPath)
	docker := NewDockerClient(*dockerSock)
	engine := NewReaperEngine(docker, cfg.IdleSeconds, cfg.Domain, cfg.ExemptProjects)
	relay := NewProxyAndDNSRelay(engine)
	handler := buildControlMux(engine, relay)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go engine.WatchDockerEvents(ctx)

	go func() {
		if err := StartNetstack(); err != nil {
			log.Printf("[firn-guestd] netstack warning: %v", err)
		}
	}()
	go func() {
		if err := serveShellBridge(vsockShellPort); err != nil {
			log.Printf("[firn-guestd] shell bridge exited: %v", err)
		}
	}()
	go func() {
		if err := serveSSHAgentBridge(guestSSHAgentSock); err != nil {
			log.Printf("[firn-guestd] ssh-agent bridge exited: %v", err)
		}
	}()
	go func() {
		if err := serveDockerBridge(2375, *dockerSock); err != nil {
			log.Printf("[firn-guestd] docker vsock bridge exited: %v", err)
		}
	}()
	go func() {
		if err := serveTunnelBridge(2377); err != nil {
			log.Printf("[firn-guestd] tcp tunnel bridge exited: %v", err)
		}
	}()
	go func() {
		if err := relay.ServeHTTPProxy("0.0.0.0:3128"); err != nil {
			log.Printf("[firn-guestd] proxy relay exited: %v", err)
		}
	}()
	go func() {
		if err := relay.ServeDNS("0.0.0.0:53"); err != nil {
			log.Printf("[firn-guestd] dns relay exited: %v", err)
		}
	}()

	vsockLn, err := ListenVsock(2376)
	if err != nil {
		log.Fatalf("[firn-guestd] failed to bind vsock:2376: %v", err)
	}
	log.Printf("[firn-guestd] control HTTP server listening on vsock:2376")
	go func() {
		if err := (&http.Server{Handler: handler}).Serve(vsockLn); err != nil {
			log.Printf("[firn-guestd] vsock http server exited: %v", err)
		}
	}()

	if *debugSock != "" {
		_ = os.MkdirAll(filepath.Dir(*debugSock), 0o755)
		_ = os.Remove(*debugSock)
		if unixLn, err := net.Listen("unix", *debugSock); err == nil {
			_ = os.Chmod(*debugSock, 0o666)
			go func() {
				_ = (&http.Server{Handler: handler}).Serve(unixLn)
			}()
		}
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	ticker := time.NewTicker(time.Duration(cfg.PollSeconds) * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if _, err := engine.ReapIdleOnce(time.Now()); err != nil {
				log.Printf("[firn-guestd] idle reap error: %v", err)
			}
		}
	}
}
