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
	"sync"
	"syscall"
	"testing"
	"time"
	"unsafe"

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
	x, e := os.Stat(a)
	if e != nil {
		return false
	}
	y, e := os.Stat(b)
	return e == nil && os.SameFile(x, y)
}
func TestWindowsDirectoryIdentityIncludesVerbatimAndShortAliases(t *testing.T) {
	dir := t.TempDir()
	if !sameDirectory(dir, `\\?\`+dir) {
		t.Fatal("verbatim path should name same directory")
	}
	p, err := syscall.UTF16PtrFromString(dir)
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]uint16, 32768)
	n, _, err := syscall.NewLazyDLL("kernel32.dll").NewProc("GetLongPathNameW").Call(uintptr(unsafe.Pointer(p)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || n >= uintptr(len(buf)) {
		t.Fatal("long path normalization failed", err)
	}
	if !sameDirectory(dir, syscall.UTF16ToString(buf[:n])) {
		t.Fatal("short and long Windows aliases should match")
	}
}

// Trace both sides of the renderer/PTY boundary when native CI fails.
type tracedTerminal struct {
	*backend.Terminal
	mu             sync.Mutex
	sent, received []byte
}

func (x *tracedTerminal) Write(p []byte) (int, error) {
	x.mu.Lock()
	x.sent = append(x.sent, p...)
	x.mu.Unlock()
	return x.Terminal.Write(p)
}
func (x *tracedTerminal) Read(p []byte) (int, error) {
	n, e := x.Terminal.Read(p)
	x.mu.Lock()
	x.received = append(x.received, p[:n]...)
	if len(x.received) > 8192 {
		x.received = x.received[len(x.received)-8192:]
	}
	x.mu.Unlock()
	return n, e
}
func (x *tracedTerminal) diagnostic() string {
	x.mu.Lock()
	defer x.mu.Unlock()
	return fmt.Sprintf("renderer sent=%q\nPTY output tail=%q", x.sent, x.received)
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
	trace := &tracedTerminal{Terminal: stream}
	renderer, e := terminal.New(terminal.Options{Conn: trace, OnKey: func(mods ui.Modifiers, key ui.Key) bool { t.Logf("terminal key: %v %v", mods, key); return false }, Theme: terminal.DarkTheme(), Font: terminal.Font{Family: "monospace", Size: 12}})
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
		r, _ := tt.Find("Terminal screen")
		t.Logf("terminal bounds=%+v focused=%v", r, tt.Focused("Terminal screen"))
		for _, p := range []string{"native-cwd-*"} {
			files, _ := filepath.Glob(filepath.Join(root, p))
			for _, f := range files {
				data, err := os.ReadFile(f)
				t.Logf("cwd evidence %s: %q %v", f, data, err)
			}
		}
		t.Fatalf("Windows integration timed out: %+v\n%s\n%s", c.Snapshot(), renderer.Text(), trace.diagnostic())
	}
	command := func(s string) {
		t.Helper()
		if e := tt.Click("Terminal screen"); e != nil {
			t.Fatal(e)
		}
		if !tt.Focused("Terminal screen") {
			r, _ := tt.Find("Terminal screen")
			t.Fatalf("terminal click did not focus input; bounds=%+v text=%v", r, tt.Texts())
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
	// Exercise the renderer queue independently of hit testing.
	rawReady := filepath.Join(root, "queue-ready")
	renderer.Send([]byte("[IO.File]::WriteAllText(" + psLiteral(rawReady) + ", 'ready')\r"))
	pump(func() bool { _, e := os.Stat(rawReady); return e == nil })
	// Exercise actual UI navigation followed by native process and PS cwd checks.
	if e = tt.Click(filepath.Base(child)); e != nil {
		t.Fatal(e)
	}
	tt.Key(0, ui.KeyEnter)
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, child) })
	verifyCwd(child)
	t.Log("UI navigation confirmed by PowerShell and native child cwd")
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
	interruptReady := filepath.Join(root, "interrupt-ready")
	interrupted := filepath.Join(root, "interrupted")
	command("[IO.File]::WriteAllText(" + psLiteral(interruptReady) + ", 'ready'); try { while($true) { Start-Sleep -Milliseconds 100 } } finally { [IO.File]::WriteAllText(" + psLiteral(interrupted) + ", 'stopped') }")
	pump(func() bool { _, e := os.Stat(interruptReady); return e == nil })
	tt.Key(ui.Ctrl, ui.KeyC)
	pump(func() bool { _, e := os.Stat(interrupted); return e == nil })
	verifyCwd(child)
	command("Set-Location -LiteralPath " + psLiteral(shellDir))
	pump(func() bool { return c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, shellDir) })
	verifyCwd(shellDir)
	// Check native child cwd across drives when the host has another writable volume.
	crossDrive := false
	for _, base := range []string{os.Getenv("USERPROFILE"), os.Getenv("RUNNER_TEMP")} {
		if base == "" || strings.EqualFold(filepath.VolumeName(base), filepath.VolumeName(root)) {
			continue
		}
		other, err := os.MkdirTemp(base, "tf-cross-drive-")
		if err != nil {
			continue
		}
		t.Cleanup(func() { os.RemoveAll(other) })
		c.Navigate(other)
		pump(func() bool {
			return !c.Snapshot().Loading && c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, other)
		})
		verifyCwd(other)
		c.Navigate(shellDir)
		pump(func() bool {
			return !c.Snapshot().Loading && c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, shellDir)
		})
		verifyCwd(shellDir)
		t.Logf("Cross-drive PowerShell and native child cwd verified: %s", filepath.VolumeName(other))
		crossDrive = true
		break
	}
	if !crossDrive {
		t.Log("Cross-drive runtime case unavailable: no second writable volume")
	}
	// Rapid navigation must settle on the latest path and actual shell cwd.
	c.Navigate(shellDir)
	c.Navigate(child)
	pump(func() bool {
		return !c.Snapshot().Loading && c.Snapshot().Sync == "Synced" && sameDirectory(c.Snapshot().Directory, child)
	})
	verifyCwd(child)
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
	// Keep the path valid to core: only PowerShell rejects it, so the error
	// must travel through completion.json rather than filesystem validation.
	command("$global:tfRejectedTarget=" + psLiteral(doomed) + "; function global:Set-Location { [CmdletBinding()] param([string]$LiteralPath); if ($LiteralPath -eq $global:tfRejectedTarget) { throw 'injected shell location failure' }; Microsoft.PowerShell.Management\\Set-Location -LiteralPath $LiteralPath }")
	verifyCwd(busyTarget)
	c.Navigate(doomed)
	pump(func() bool { return strings.Contains(c.Snapshot().Error, "terminal_control_failed") })
	verifyCwd(busyTarget)
	command("Remove-Item Function:\\Set-Location; Remove-Variable tfRejectedTarget -Scope Global")
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
