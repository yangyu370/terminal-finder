//go:build windows

package integration

import (
	"context"
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
	"terminal-finder-mygo/internal/backend"
	"terminal-finder-mygo/internal/finderui"
	"terminal-finder-mygo/internal/launch"
	"terminal-finder-mygo/internal/workspace"
)

// A real native executable proves inherited cwd, independently of PowerShell's
// location provider and the renderer's echoed command line.
func TestMain(m *testing.M) {
	if len(os.Args) == 3 && os.Args[1] == "--tf-native-cwd" {
		cwd, err := os.Getwd()
		if err != nil {
			os.Exit(2)
		}
		if os.WriteFile(os.Args[2], []byte(cwd), 0600) != nil {
			os.Exit(3)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}
func psLiteral(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
func sameDirectory(a, b string) bool {
	x, e := filepath.EvalSymlinks(a)
	if e != nil {
		return false
	}
	y, e := filepath.EvalSymlinks(b)
	return e == nil && strings.EqualFold(x, y)
}
func TestWindowsRenderedConPTYBidirectionalDirectoryAndStdinIsolation(t *testing.T) {
	binary := os.Getenv("TF_CORE_BINARY")
	if binary == "" || os.Getenv("MYGO_GHOSTTY_VT") == "" {
		t.Skip("Windows native integration needs core.exe and ghostty-vt.dll")
	}
	root := t.TempDir()
	child := filepath.Join(root, "中文 space ' quote")
	shellDir := filepath.Join(root, "from-shell")
	busyTarget := filepath.Join(root, "busy-target")
	for _, p := range []string{child, shellDir, busyTarget} {
		if e := os.Mkdir(p, 0700); e != nil {
			t.Fatal(e)
		}
	}
	if e := os.WriteFile(filepath.Join(child, "hello.txt"), []byte("real Windows core"), 0600); e != nil {
		t.Fatal(e)
	}
	t.Setenv("APPDATA", root)
	t.Setenv("LOCALAPPDATA", root)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	server, e := launch.Start(ctx, binary, "http://127.0.0.1:3587", root, filepath.Join(root, "core.log"))
	if e != nil {
		t.Fatal(e)
	}
	defer server.Close()
	api, _ := backend.New("http://127.0.0.1:3587")
	initial, e := api.Open(ctx, root)
	if e != nil {
		t.Fatal(e)
	}
	c := workspace.NewController(api, initial)
	defer c.Close()
	stream, e := api.Connect(ctx, c.Observe)
	if e != nil {
		t.Fatal(e)
	}
	defer stream.Close()
	if e = stream.Start(ctx); e != nil {
		t.Fatal(e)
	}
	c.Start(stream)
	renderer, e := terminal.New(terminal.Options{Conn: stream, Theme: terminal.DarkTheme(), Font: terminal.Font{Family: "monospace", Size: 12}})
	if e != nil {
		t.Fatal(e)
	}
	defer renderer.Close()
	b := finderui.New(c, root, root)
	b.Dark = true
	b.TerminalOpen = true
	b.Terminal = func(cx *ui.Context) { terminal.View(cx, renderer).Fill().Label("Terminal screen") }
	tt := ui.NewTester(b.View, 1120, 720)
	pump := func(condition func() bool) {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for time.Now().Before(deadline) {
			tt.Frame()
			if condition() {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("Windows integration timed out: %+v\n%s", c.Snapshot(), renderer.Text())
	}
	command := func(s string) {
		t.Helper()
		if e := tt.Click("Terminal screen"); e != nil {
			t.Fatal(e)
		}
		tt.Type(s)
		tt.Key(0, ui.KeyEnter)
	}
	verifyCwd := func(want string) {
		t.Helper()
		exe, e := os.Executable()
		if e != nil {
			t.Fatal(e)
		}
		native := filepath.Join(root, "native-cwd-"+strconv.FormatInt(time.Now().UnixNano(), 10))
		ps := native + ".ps"
		command("& " + psLiteral(exe) + " '--tf-native-cwd' " + psLiteral(native) + "; [IO.File]::WriteAllText(" + psLiteral(ps) + ", (Get-Location).ProviderPath)")
		pump(func() bool {
			a, e := os.ReadFile(native)
			if e != nil {
				return false
			}
			z, e := os.ReadFile(ps)
			return e == nil && sameDirectory(string(a), want) && sameDirectory(string(z), want)
		})
	}
	pump(func() bool { return c.Snapshot().Sync == "Synced" })
	// Exercise actual UI navigation followed by native process and PS cwd checks.
	if e = tt.Click(filepath.Base(child)); e != nil {
		t.Fatal(e)
	}
	tt.Key(0, ui.KeyEnter)
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, child) })
	verifyCwd(child)
	command("Write-Output ('__UTF8__' + [char]0x4f60 + [char]0x597d); Write-Output ('__PS_PID__' + $PID)")
	pump(func() bool {
		return strings.Contains(renderer.Text(), "__UTF8__你好") && regexp.MustCompile(`__PS_PID__([0-9]+)`).MatchString(renderer.Text())
	})
	match := regexp.MustCompile(`__PS_PID__([0-9]+)`).FindStringSubmatch(renderer.Text())
	pid, _ := strconv.ParseUint(match[1], 10, 32)
	kernel := syscall.NewLazyDLL("kernel32.dll")
	openProcess := kernel.NewProc("OpenProcess")
	wait := kernel.NewProc("WaitForSingleObject")
	closeHandle := kernel.NewProc("CloseHandle")
	handle, _, err := openProcess.Call(0x00100000, 0, uintptr(pid))
	if handle == 0 {
		t.Fatal("cannot observe shell lifecycle", err)
	}
	defer closeHandle.Call(handle)
	command("Set-Location -LiteralPath " + psLiteral(shellDir))
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, shellDir) })
	verifyCwd(shellDir)
	// Rapid navigation must settle on the latest path and actual shell cwd.
	c.Navigate(child)
	c.Navigate(shellDir)
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, shellDir) })
	ready := filepath.Join(root, "stdin-ready")
	captured := filepath.Join(root, "stdin-captured")
	command("[IO.File]::WriteAllText(" + psLiteral(ready) + ", 'ready'); $tfLine=[Console]::ReadLine(); [IO.File]::WriteAllText(" + psLiteral(captured) + ", $tfLine)")
	pump(func() bool { _, e := os.Stat(ready); return e == nil })
	c.Navigate(busyTarget)
	pump(func() bool {
		return c.Snapshot().Sync == "Waiting for terminal" && sameDirectory(c.Snapshot().Directory, busyTarget)
	})
	time.Sleep(500 * time.Millisecond)
	if _, e := os.Stat(captured); !os.IsNotExist(e) {
		t.Fatal("foreground stdin unexpectedly received input")
	}
	if _, e = stream.Write([]byte("user-input\r")); e != nil {
		t.Fatal(e)
	}
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, busyTarget) })
	got, e := os.ReadFile(captured)
	if e != nil || string(got) != "user-input" {
		t.Fatalf("stdin injection: %q %v", got, e)
	}
	verifyCwd(busyTarget)
	c.Navigate(filepath.Join(root, "missing"))
	pump(func() bool { return c.Snapshot().Error != "" })
	if !sameDirectory(c.Snapshot().Directory, busyTarget) {
		t.Fatal("failed navigation lost listing")
	}
	// The shell reports terminal-side cd failure; it must not wait forever.
	doomed := filepath.Join(root, "doomed")
	if e = os.Mkdir(doomed, 0700); e != nil {
		t.Fatal(e)
	}
	ready2 := filepath.Join(root, "busy2")
	command("[IO.File]::WriteAllText(" + psLiteral(ready2) + ", 'ready'); $null=[Console]::ReadLine()")
	pump(func() bool { _, e := os.Stat(ready2); return e == nil })
	c.Navigate(doomed)
	pump(func() bool {
		return c.Snapshot().Sync == "Waiting for terminal" && sameDirectory(c.Snapshot().Directory, doomed)
	})
	if e = os.Remove(doomed); e != nil {
		t.Fatal(e)
	}
	stream.Write([]byte("finish\r"))
	pump(func() bool { return c.Snapshot().Sync == "Sync blocked" })
	c.Navigate(root)
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, root) })
	tt.Key(ui.Cmd, ui.KeyJ)
	if b.TerminalOpen {
		t.Fatal("panel failed to collapse")
	}
	tt.Key(ui.Cmd, ui.KeyJ)
	if !b.TerminalOpen {
		t.Fatal("panel failed to restore")
	}
	if e = stream.Resize(120, 35); e != nil {
		t.Fatal(e)
	}
	if path := os.Getenv("TF_PREVIEW"); path != "" {
		f, e := os.Create(path)
		if e != nil {
			t.Fatal(e)
		}
		e = png.Encode(f, tt.Image())
		f.Close()
		if e != nil {
			t.Fatal(e)
		}
	}
	stream.Close()
	pump(func() bool { return c.Snapshot().Disconnected })
	pump(func() bool { status, _, _ := wait.Call(handle, 0); return status == 0 })
	t.Log(fmt.Sprintf("Windows native ConPTY/PowerShell PID %d exited; real rendered cwd and stdin isolation verified", pid))
}
