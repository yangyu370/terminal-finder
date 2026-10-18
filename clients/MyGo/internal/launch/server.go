package launch

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"sync"
	"time"

	"terminal-finder-mygo/internal/backend"
)

// Server owns only the child it starts. It never kills a process found on a port.
type Server struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	done  chan struct{}
	once  sync.Once
	err   error
}

func Start(ctx context.Context, binary, endpoint, directory, logPath string) (*Server, error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}
	if u.Host != "127.0.0.1:3587" {
		return nil, fmt.Errorf("managed Rust server uses http://127.0.0.1:3587; use -connect for another endpoint")
	}
	if conn, e := net.DialTimeout("tcp", u.Host, 300*time.Millisecond); e == nil {
		conn.Close()
		return nil, fmt.Errorf("port 3587 is occupied; use -connect explicitly to share an existing core")
	}
	client, err := backend.New(endpoint)
	if err != nil {
		return nil, err
	}
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(binary)
	cmd.Dir = directory
	cmd.Env = append(os.Environ(), "RUST_LOG=warn", "TERM=xterm-256color", "COLORTERM=truecolor")
	// The existing optional server validates OSC 7 authorities against HOST.
	// GUI launches often have neither HOST nor HOSTNAME in their environment.
	host, err := os.Hostname()
	if err != nil {
		log.Close()
		return nil, err
	}
	cmd.Env = append(cmd.Env, "HOST="+host)
	cmd.Stdout = log
	cmd.Stderr = log
	stdin, err := cmd.StdinPipe()
	if err != nil {
		log.Close()
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		stdin.Close()
		log.Close()
		return nil, err
	}
	s := &Server{cmd: cmd, stdin: stdin, done: make(chan struct{})}
	go func() { s.err = cmd.Wait(); log.Close(); close(s.done) }()
	ticker := time.NewTicker(40 * time.Millisecond)
	defer ticker.Stop()
	timeout := time.NewTimer(15 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case <-ctx.Done():
			s.Close()
			return nil, ctx.Err()
		case <-s.done:
			return nil, fmt.Errorf("Rust core exited: %v (see %s)", s.err, logPath)
		case <-timeout.C:
			s.Close()
			return nil, fmt.Errorf("Rust core startup timed out (see %s)", logPath)
		case <-ticker.C:
			probe, cancel := context.WithTimeout(ctx, 300*time.Millisecond)
			err = client.Health(probe)
			cancel()
			if err == nil {
				return s, nil
			}
		}
	}
}
func (s *Server) Close() {
	if s == nil {
		return
	}
	s.once.Do(func() {
		s.stdin.Close()
		select {
		case <-s.done:
			return
		case <-time.After(3 * time.Second):
			s.cmd.Process.Kill()
			<-s.done
		}
	})
}
