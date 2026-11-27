package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sync"

	"github.com/creack/pty"
)

const (
	vsockShellPort    = 2382
	vsockSSHAgentPort = 2383
	guestSSHAgentSock = "/run/firn/ssh-agent.sock"

	shellFrameData   byte = 0x00
	shellFrameResize byte = 0x01
	shellFrameExit   byte = 0x02
	shellFrameEOF    byte = 0x03
)

type shellStartRequest struct {
	Argv    []string `json:"argv"`
	Cwd     string   `json:"cwd,omitempty"`
	Machine string   `json:"machine,omitempty"`
	Rows    uint16   `json:"rows,omitempty"`
	Cols    uint16   `json:"cols,omitempty"`
	TTY     bool     `json:"tty"`
	Env     []string `json:"env,omitempty"`
}

func writeShellFrame(mu *sync.Mutex, w io.Writer, kind byte, payload []byte) error {
	mu.Lock()
	defer mu.Unlock()
	var hdr [5]byte
	hdr[0] = kind
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		if _, err := w.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

func readShellFrame(r io.Reader) (byte, []byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	if n > 8*1024*1024 {
		return 0, nil, errors.New("shell frame too large")
	}
	var payload []byte
	if n > 0 {
		payload = make([]byte, n)
		if _, err := io.ReadFull(r, payload); err != nil {
			return 0, nil, err
		}
	}
	return hdr[0], payload, nil
}

func serveShellBridge(vsockPort uint32, defaultHostHome string) error {
	ln, err := ListenVsock(vsockPort)
	if err != nil {
		return err
	}
	log.Printf("[firn-guestd] interactive shell bridge listening on vsock:%d", vsockPort)
	for {
		vc, err := ln.Accept()
		if err != nil {
			return err
		}
		go handleShellSession(vc, defaultHostHome)
	}
}

func handleShellSession(conn net.Conn, defaultHostHome string) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return
	}
	var req shellStartRequest
	if err := json.Unmarshal(line, &req); err != nil {
		return
	}
	if len(req.Argv) == 0 {
		req.Argv = []string{"/bin/sh", "-l"}
	}
	if req.Rows == 0 {
		req.Rows = 24
	}
	if req.Cols == 0 {
		req.Cols = 80
	}

	var cmd *exec.Cmd
	if req.Machine != "" {
		cleanName, nerr := sanitizeMachineName(req.Machine)
		if nerr != nil {
			return
		}
		execArgs := []string{"exec", "-i"}
		if req.TTY {
			execArgs = append(execArgs, "-t")
		}
		workdir := req.Cwd
		if workdir == "" {
			workdir = defaultHostHome
		}
		if workdir != "" {
			execArgs = append(execArgs, "-w", workdir)
		}
		execArgs = append(execArgs, "-e", "TERM=xterm-256color", "-e", "SSH_AUTH_SOCK="+guestSSHAgentSock)
		for _, e := range req.Env {
			execArgs = append(execArgs, "-e", e)
		}
		execArgs = append(execArgs, machineContainerName(cleanName))
		execArgs = append(execArgs, req.Argv...)
		cmd = exec.Command("docker", execArgs...)
	} else {
		cmd = exec.Command(req.Argv[0], req.Argv[1:]...)
		if req.Cwd != "" {
			cmd.Dir = req.Cwd
		}
		env := append(os.Environ(),
			"TERM=xterm-256color",
			"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
			"SSH_AUTH_SOCK="+guestSSHAgentSock,
		)
		env = append(env, req.Env...)
		cmd.Env = env
	}

	var writeMu sync.Mutex
	sendExit := func(code int) {
		var buf [4]byte
		binary.BigEndian.PutUint32(buf[:], uint32(int32(code)))
		_ = writeShellFrame(&writeMu, conn, shellFrameExit, buf[:])
	}

	if req.TTY {
		ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: req.Rows, Cols: req.Cols})
		if err != nil {
			_ = writeShellFrame(&writeMu, conn, shellFrameData, []byte(err.Error()+"\r\n"))
			sendExit(127)
			return
		}
		defer ptmx.Close()

		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 32*1024)
			for {
				n, rerr := ptmx.Read(buf)
				if n > 0 {
					if werr := writeShellFrame(&writeMu, conn, shellFrameData, buf[:n]); werr != nil {
						return
					}
				}
				if rerr != nil {
					return
				}
			}
		}()

		go func() {
			for {
				kind, payload, rerr := readShellFrame(reader)
				if rerr != nil {
					return
				}
				switch kind {
				case shellFrameData:
					if len(payload) > 0 {
						_, _ = ptmx.Write(payload)
					}
				case shellFrameResize:
					if len(payload) == 4 {
						rows := binary.BigEndian.Uint16(payload[0:2])
						cols := binary.BigEndian.Uint16(payload[2:4])
						_ = pty.Setsize(ptmx, &pty.Winsize{Rows: rows, Cols: cols})
					}
				case shellFrameEOF:
					_, _ = ptmx.Write([]byte{0x04})
				}
			}
		}()

		waitErr := cmd.Wait()
		_ = ptmx.Close()
		wg.Wait()
		code := 0
		if waitErr != nil {
			var exitErr *exec.ExitError
			if errors.As(waitErr, &exitErr) {
				code = exitErr.ExitCode()
			} else {
				code = 1
			}
		}
		sendExit(code)
		return
	}

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		sendExit(1)
		return
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		sendExit(1)
		return
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		sendExit(1)
		return
	}
	if err := cmd.Start(); err != nil {
		_ = writeShellFrame(&writeMu, conn, shellFrameData, []byte(err.Error()+"\n"))
		sendExit(127)
		return
	}

	var outWG sync.WaitGroup
	streamOut := func(rc io.ReadCloser) {
		defer outWG.Done()
		buf := make([]byte, 32*1024)
		for {
			n, rerr := rc.Read(buf)
			if n > 0 {
				_ = writeShellFrame(&writeMu, conn, shellFrameData, buf[:n])
			}
			if rerr != nil {
				return
			}
		}
	}
	outWG.Add(2)
	go streamOut(stdoutPipe)
	go streamOut(stderrPipe)

	go func() {
		defer stdinPipe.Close()
		for {
			kind, payload, rerr := readShellFrame(reader)
			if rerr != nil {
				return
			}
			switch kind {
			case shellFrameData:
				if len(payload) > 0 {
					if _, werr := stdinPipe.Write(payload); werr != nil {
						return
					}
				}
			case shellFrameEOF:
				return
			}
		}
	}()

	outWG.Wait()
	waitErr := cmd.Wait()
	code := 0
	if waitErr != nil {
		var exitErr *exec.ExitError
		if errors.As(waitErr, &exitErr) {
			code = exitErr.ExitCode()
		} else {
			code = 1
		}
	}
	sendExit(code)
}

func serveSSHAgentBridge(sockPath string) error {
	_ = os.MkdirAll(filepath.Dir(sockPath), 0o755)
	_ = os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		return err
	}
	_ = os.Chmod(sockPath, 0o666)
	_ = os.WriteFile("/etc/profile.d/firn-ssh.sh", []byte("export SSH_AUTH_SOCK="+sockPath+"\n"), 0o644)
	log.Printf("[firn-guestd] ssh-agent bridge listening on %s -> host vsock:%d", sockPath, vsockSSHAgentPort)
	for {
		client, err := ln.Accept()
		if err != nil {
			return err
		}
		go func(c net.Conn) {
			upstream, err := DialVsockHost(vsockSSHAgentPort)
			if err != nil {
				_ = c.Close()
				return
			}
			spliceHalfClose(c, upstream)
		}(client)
	}
}
