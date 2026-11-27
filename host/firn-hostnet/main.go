package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	if len(os.Args) > 1 && os.Args[1] == "utun" {
		if err := runUtunSubcommand(os.Args[2:]); err != nil {
			log.Fatalf("[firn-utun] fatal: %v", err)
		}
		return
	}

	homeDefault, _ := os.UserHomeDir()
	stateDefault := os.Getenv("FIRN_HOME")
	if stateDefault == "" && homeDefault != "" {
		stateDefault = filepath.Join(homeDefault, ".firn")
	}
	runDefault := filepath.Join(stateDefault, "run")
	certsDefault := filepath.Join(stateDefault, "certs")

	hostHome := flag.String("host-home", homeDefault, "Host home directory served by firnfs")
	vmnetFDSock := flag.String("vmnet-fd-sock", filepath.Join(runDefault, "vmnet-fd.sock"), "Unix socket receiving VM L2 socketpair fd via SCM_RIGHTS")
	firnfsSock := flag.String("firnfs-sock", filepath.Join(runDefault, "firnfs.sock"), "Unix socket serving firnfs RPC for AF_VSOCK relay")
	controlSock := flag.String("control-sock", filepath.Join(runDefault, "hostnet.sock"), "HTTP control Unix socket")
	firndSock := flag.String("firnd-sock", filepath.Join(runDefault, "firnd.sock"), "firnd daemon control socket")
	utunSock := flag.String("utun-sock", filepath.Join(runDefault, "utun.sock"), "Host utun packet bridge Unix socket")
	domain := flag.String("domain", "firn.local", "Local domain")
	httpPort := flag.Int("http-proxy-port", 8088, "HTTP domain proxy port")
	httpsPort := flag.Int("https-proxy-port", 8443, "HTTPS domain proxy port")
	caCert := flag.String("ca-cert", filepath.Join(certsDefault, "ca.crt"), "Root CA cert path")
	caKey := flag.String("ca-key", filepath.Join(certsDefault, "ca.key"), "Root CA key path")
	portForward := flag.Bool("port-forward", true, "Bind loopback host ports in firn-hostnet")
	mtu := flag.Int("mtu", 16384, "L3 MTU for jumbo virtio-net")
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	fsServer, err := NewFirnFSServer(*hostHome)
	if err != nil {
		log.Fatalf("[firn-hostnet] firnfs init failed: %v", err)
	}
	if *firnfsSock != "" {
		if err := fsServer.ServeUnix(ctx, *firnfsSock); err != nil {
			log.Fatalf("[firn-hostnet] firnfs unix socket failed: %v", err)
		}
	}

	engine, err := NewNetEngine(NetEngineConfig{
		MTU:         uint32(*mtu),
		VMNetFDSock: *vmnetFDSock,
		UtunSock:    *utunSock,
		FSServer:    fsServer,
		FirndSock:   *firndSock,
	})
	if err != nil {
		log.Fatalf("[firn-hostnet] netstack init failed: %v", err)
	}
	defer engine.Close()

	proxyMgr := NewProxyManager(ProxyManagerConfig{
		Domain:            *domain,
		HTTPPort:          uint16(*httpPort),
		HTTPSPort:         uint16(*httpsPort),
		CACert:            *caCert,
		CAKey:             *caKey,
		FirndSock:         *firndSock,
		Engine:            engine,
		EnablePortForward: *portForward,
	})
	engine.SetContainerLookup(proxyMgr.LookupPausedByIP)
	if err := proxyMgr.Start(); err != nil {
		log.Fatalf("[firn-hostnet] proxy init failed: %v", err)
	}
	defer proxyMgr.Close()

	if err := serveControlSocket(ctx, *controlSock, engine, proxyMgr, fsServer); err != nil {
		log.Fatalf("[firn-hostnet] control socket failed: %v", err)
	}

	log.Printf("[firn-hostnet] ready (mtu=%d, http=:%d, https=:%d, firnfs=10.89.0.1:2385)", *mtu, *httpPort, *httpsPort)
	<-ctx.Done()
	log.Printf("[firn-hostnet] shutting down")
}
