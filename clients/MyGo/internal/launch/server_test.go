package launch

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestManagedServerReceivesLocalHostname(t *testing.T) {
	root := t.TempDir()
	output := filepath.Join(root, "host")
	script, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TF_LAUNCH_HELPER_OUTPUT", output)
	t.Setenv("HOST", "")
	t.Setenv("HOSTNAME", "")
	t.Setenv("TERM", "dumb")
	_, err = Start(context.Background(), script, "http://127.0.0.1:3587", root, filepath.Join(root, "core.log"))
	if err == nil {
		t.Fatal("expected child exit error")
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	host, _ := os.Hostname()
	want := host + "|xterm-256color"
	if string(got) != want {
		t.Fatalf("child HOST=%q, want %q for Rust cwd URL validation", got, want)
	}
}

// The test binary is a portable child process; no /bin/sh fixture on Windows.
func TestMain(m *testing.M) {
	if output := os.Getenv("TF_LAUNCH_HELPER_OUTPUT"); output != "" {
		if err := os.WriteFile(output, []byte(os.Getenv("HOST")+"|"+os.Getenv("TERM")), 0600); err != nil {
			os.Exit(8)
		}
		os.Exit(7)
	}
	os.Exit(m.Run())
}
