package integration

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"terminal-finder-mygo/internal/backend"
	"terminal-finder-mygo/internal/launch"
	"terminal-finder-mygo/internal/workspace"
)

func eventually(t *testing.T, c *workspace.Controller, condition func(workspace.Snapshot) bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		s := c.Snapshot()
		if condition(s) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out; last state: %+v", c.Snapshot())
}
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }

func TestRealRustPTYBidirectionalSync(t *testing.T) {
	binary := os.Getenv("TF_CORE_BINARY")
	if binary == "" {
		t.Skip("set TF_CORE_BINARY to run real core integration")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	a := filepath.Join(root, "中文 space ' quote")
	b := filepath.Join(root, "from-shell")
	busy := filepath.Join(root, "busy-target")
	for _, p := range []string{a, b, busy} {
		if err = os.Mkdir(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	// Do not load or mutate the developer's shell configuration during tests.
	t.Setenv("HOME", root)
	t.Setenv("ZDOTDIR", root)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	server, err := launch.Start(ctx, binary, "http://127.0.0.1:3587", root, filepath.Join(root, "core.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	api, _ := backend.New("http://127.0.0.1:3587")
	initial, err := api.Open(ctx, root)
	if err != nil {
		t.Fatal(err)
	}
	c := workspace.NewController(api, initial)
	defer c.Close()
	term, err := api.Connect(ctx, c.Observe)
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	if err = term.Start(ctx); err != nil {
		t.Fatal(err)
	}
	c.Start(term)
	ptyLog, err := os.Create(filepath.Join(root, "pty.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer ptyLog.Close()
	t.Cleanup(func() {
		if t.Failed() {
			data, _ := os.ReadFile(filepath.Join(root, "pty.log"))
			t.Logf("PTY output: %q", data)
		}
	})
	outputDone := make(chan struct{})
	go func() { io.Copy(ptyLog, term); close(outputDone) }()
	eventually(t, c, func(s workspace.Snapshot) bool { return s.Sync == "Synced" && s.Directory == root })
	c.Navigate(a)
	eventually(t, c, func(s workspace.Snapshot) bool {
		return s.Sync == "Synced" && s.Directory == a && s.TerminalDirectory == a
	})
	if _, err = term.Write([]byte("cd -- " + quote(b) + "\r")); err != nil {
		t.Fatal(err)
	}
	eventually(t, c, func(s workspace.Snapshot) bool {
		return s.Sync == "Synced" && s.Directory == b && s.TerminalDirectory == b
	})
	// While a program reads stdin, UI navigation must never type a cd into it.
	// cat's output file is the evidence: injected commands would be persisted.
	captured := filepath.Join(root, "stdin.txt")
	if _, err = term.Write([]byte("cat > " + quote(captured) + "\r")); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, e := os.Stat(captured); e == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("cat did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	c.Navigate(busy)
	eventually(t, c, func(s workspace.Snapshot) bool { return s.Directory == busy && s.Sync == "Waiting for terminal" })
	if _, err = term.Write([]byte("user-input\n")); err != nil {
		t.Fatal(err)
	}
	// End cat at the next empty line. Pending cd is applied by precmd.
	if _, err = term.Write([]byte{4}); err != nil {
		t.Fatal(err)
	}
	eventually(t, c, func(s workspace.Snapshot) bool {
		return s.Sync == "Synced" && s.Directory == busy && s.TerminalDirectory == busy
	})
	data, err := os.ReadFile(captured)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "user-input\n" {
		t.Fatalf("foreground program received unexpected input: %q", data)
	}
	c.Navigate(filepath.Join(root, "missing"))
	eventually(t, c, func(s workspace.Snapshot) bool { return s.Error != "" })
	if c.Snapshot().Directory != busy {
		t.Fatal("failed navigation changed browser")
	}
	// Closing the socket must also reap the Rust-owned PTY shell.
	term.Close()
	select {
	case <-outputDone:
	case <-ctx.Done():
		t.Fatal("output worker leaked")
	}
	eventually(t, c, func(s workspace.Snapshot) bool { return s.Disconnected })
}
