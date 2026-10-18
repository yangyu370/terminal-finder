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
	script := filepath.Join(root, "probe")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s|%s' \"$HOST\" \"$TERM\" > '"+output+"'\nexit 7\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOST", "")
	t.Setenv("HOSTNAME", "")
	t.Setenv("TERM", "dumb")
	_, err := Start(context.Background(), script, "http://127.0.0.1:3587", root, filepath.Join(root, "core.log"))
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
