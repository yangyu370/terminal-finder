// The self-drawn client shares no AppKit component code with the native experiment.
package main

import (
	"context"
	"flag"
	"fmt"
	"image/png"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/egoist/mygo"
	"github.com/egoist/mygo/plugins/terminal"
	"github.com/egoist/mygo/ui"
	"terminal-finder-mygo/internal/backend"
	"terminal-finder-mygo/internal/finderui"
	"terminal-finder-mygo/internal/launch"
	"terminal-finder-mygo/internal/workspace"
)

func main() {
	if err := run(); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}
func run() error {
	home, _ := os.UserHomeDir()
	exe, _ := os.Executable()
	defaultCore := os.Getenv("TF_CORE_BINARY")
	if defaultCore == "" {
		defaultCore = launch.DefaultCorePath(exe, runtime.GOOS)
	}
	endpoint := flag.String("endpoint", "http://127.0.0.1:3587", "loopback Rust core origin")
	path := flag.String("workspace", home, "initial local directory")
	core := flag.String("core", defaultCore, "Rust server binary to start")
	connect := flag.Bool("connect", false, "explicitly attach to an existing optional server")
	demo := flag.Bool("demo", false, "standalone component sample data; no backend or shell")
	dark := flag.Bool("dark", false, "use the dark component palette")
	capture := flag.String("capture", "", "with --demo, export a 2x component PNG instead of opening a window")
	logPath := flag.String("log", filepath.Join(os.TempDir(), "terminal-finder-drawn-core.log"), "managed core log")
	flag.Parse()
	if *capture != "" && !*demo {
		return fmt.Errorf("--capture requires --demo")
	}
	var b *finderui.Browser
	var renderer *terminal.Terminal
	var stream *backend.Terminal
	if *demo {
		b = finderui.NewDemo()
		b.Terminal = func(c *ui.Context) {
			ui.Text(c, "Component preview · no shell session").Font("monospace").FontSize(12).TextColor(ui.Hex("#aaaab0"))
		}
	} else {
		initialPath, err := filepath.Abs(*path)
		if err != nil {
			return err
		}
		client, err := backend.New(*endpoint)
		if err != nil {
			return err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if !*connect {
			server, err := launch.Start(ctx, *core, *endpoint, initialPath, *logPath)
			if err != nil {
				return err
			}
			defer server.Close()
		}
		if err = client.Health(ctx); err != nil {
			return err
		}
		initial, err := client.Open(ctx, initialPath)
		if err != nil {
			return err
		}
		controller := workspace.NewController(client, initial)
		defer controller.Close()
		stream, err = client.Connect(ctx, controller.Observe)
		if err != nil {
			return err
		}
		defer stream.Close()
		if err = stream.Start(ctx); err != nil {
			return fmt.Errorf("workspace terminal: %w", err)
		}
		controller.Start(stream)
		b = finderui.New(controller, home, initial.State.CurrentDirectory)
		// Notifications are installed after the window exists, below.
		defer controller.SetNotify(nil)
	}
	b.Dark = *dark
	if *capture != "" {
		b.PreviewChrome = true
		tt := ui.NewTester(b.View, 1120, 720)
		tt.SetScale(2)
		f, err := os.Create(*capture)
		if err != nil {
			return err
		}
		defer f.Close()
		return png.Encode(f, tt.Image())
	}
	mygo.App.SetName("Terminal Finder Drawn")
	var runError error
	defer func() {
		if renderer != nil {
			renderer.Close()
		}
	}()
	mygo.App.WhenReady(func() {
		focusTerminal := false
		if !*demo {
			theme := terminal.DarkTheme()
			theme.Background = ui.Hex("#1e1e20")
			theme.Foreground = ui.Hex("#d9d9df")
			theme.Cursor = ui.Hex("#e4e4e8")
			var err error
			renderer, err = terminal.New(terminal.Options{Conn: stream, Font: terminal.Font{Family: "monospace", Size: 12}, Theme: theme, DarkTheme: theme})
			if err != nil {
				runError = err
				mygo.App.Quit()
				return
			}
			b.Terminal = func(c *ui.Context) {
				e := terminal.View(c, renderer).Fill().Label("Terminal screen")
				if focusTerminal {
					e.Focus()
					focusTerminal = false
				}
			}
			b.FocusTerminal = func() { focusTerminal = true }
			b.TerminalOpen = true
		}
		b.OpenFile = func(path string) {
			if err := mygo.Shell.OpenPath(path); err != nil {
				log.Print(err)
			}
		}
		title := "Terminal Finder Drawn"
		if *demo {
			title += " — Component preview"
		}
		win := mygo.NewWindow(mygo.WindowOptions{Title: title, Width: 1120, Height: 720, MinWidth: 900, MinHeight: 540, UseContentSize: true, TitleBarStyle: mygo.TitleBarHiddenInset, TrafficLightPosition: &mygo.Point{X: 16, Y: 26}, TitleBarHeight: 64, BackgroundColor: "#eeeeee", Content: ui.View(b.View)})
		if controller, ok := b.Model.(*workspace.Controller); ok {
			controller.SetNotify(func() { win.Update(func() { win.SetTitle(filepath.Base(controller.Snapshot().Directory)) }) })
		}
		win.OnClosed(func() {
			if controller, ok := b.Model.(*workspace.Controller); ok {
				controller.SetNotify(nil)
			}
			mygo.App.Quit()
		})
	})
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sig)
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		select {
		case <-sig:
			mygo.App.Quit()
		case <-stop:
		}
	}()
	if err := mygo.App.Run(); err != nil {
		return err
	}
	return runError
}
