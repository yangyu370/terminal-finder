//go:build !windows

package integration

import (
	"context"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
	"terminal-finder-mygo/internal/backend"
	"terminal-finder-mygo/internal/finderui"
	"terminal-finder-mygo/internal/launch"
	"terminal-finder-mygo/internal/workspace"
)

func TestRenderedTerminalSharesDirectoryWithUI(t *testing.T) {
	binary := os.Getenv("TF_CORE_BINARY")
	if binary == "" || os.Getenv("MYGO_GHOSTTY_VT") == "" {
		t.Skip("set TF_CORE_BINARY and MYGO_GHOSTTY_VT for real rendered integration")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	child := filepath.Join(root, "MyGo workspace")
	if err = os.Mkdir(child, 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(child, "hello.txt"), []byte("real Rust workspace\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", root)
	t.Setenv("ZDOTDIR", root)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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
	stream, err := api.Connect(ctx, c.Observe)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if err = stream.Start(ctx); err != nil {
		t.Fatal(err)
	}
	c.Start(stream)
	renderer, err := terminal.New(terminal.Options{Conn: stream, Theme: terminal.DarkTheme(), DarkTheme: terminal.DarkTheme(), Font: terminal.Font{Family: "Menlo", Size: 12}})
	if err != nil {
		t.Fatal(err)
	}
	defer renderer.Close()
	browser := finderui.New(c, root, root)
	browser.TerminalOpen = true
	browser.Terminal = func(cx *ui.Context) { terminal.View(cx, renderer).Fill().Label("Terminal screen") }
	tt := ui.NewTester(browser.View, 1120, 720)
	pump := func(condition func() bool) {
		t.Helper()
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			tt.Frame()
			if condition() {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("rendered integration timed out: %+v; text=%q", c.Snapshot(), renderer.Text())
	}
	pump(func() bool { return c.Snapshot().Sync == "Synced" })
	if err = tt.Click("MyGo workspace"); err != nil {
		t.Fatal(err)
	}
	tt.Key(0, ui.KeyEnter)
	pump(func() bool {
		return c.Snapshot().Directory == child && c.Snapshot().Sync == "Synced"
	})
	if err = tt.Click("Terminal screen"); err != nil {
		t.Fatal(err)
	}
	tt.Type("printf '\\n__TF_PWD__%s\\n' \"$PWD\"")
	tt.Key(0, ui.KeyEnter)
	pump(func() bool { return strings.Contains(renderer.Text(), "__TF_PWD__"+child) })
	if output := os.Getenv("TF_PREVIEW"); output != "" {
		f, e := os.Create(output)
		if e != nil {
			t.Fatal(e)
		}
		e = png.Encode(f, tt.Image())
		f.Close()
		if e != nil {
			t.Fatal(e)
		}
	}
	if err = tt.Click("Terminal screen"); err != nil {
		t.Fatal(err)
	}
	tt.Type("cd -- " + quote(root))
	tt.Key(0, ui.KeyEnter)
	pump(func() bool { return c.Snapshot().Directory == root && c.Snapshot().Sync == "Synced" })
	// Hiding the drawn panel preserves the same Rust session and renderer.
	tt.Key(ui.Cmd, ui.KeyJ)
	if browser.TerminalOpen {
		t.Fatal("terminal did not collapse")
	}
	tt.Key(ui.Cmd, ui.KeyJ)
	if !browser.TerminalOpen {
		t.Fatal("terminal did not restore")
	}
	pump(func() bool { return c.Snapshot().Sync == "Synced" })
	tt.Key(ui.Cmd, ui.KeyL)
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type(filepath.Join(root, "missing-folder"))
	tt.Key(0, ui.KeyEnter)
	pump(func() bool { return c.Snapshot().Error != "" })
	if c.Snapshot().Directory != root {
		t.Fatal("failed UI navigation changed the core directory")
	}
	cols, rows := renderer.Size()
	if cols < 1 || rows < 1 {
		t.Fatalf("invalid viewport %dx%d", cols, rows)
	}
}
