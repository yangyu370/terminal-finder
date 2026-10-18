package finderui

import (
	"image/png"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/egoist/mygo/ui"
)

func click(t *testing.T, tt *ui.Tester, label string) {
	t.Helper()
	if err := tt.Click(label); err != nil {
		t.Fatal(err)
	}
}

func TestDrawnNavigationAndPathFailure(t *testing.T) {
	b := NewDemo()
	tt := ui.NewTester(b.View, 1120, 720)
	click(t, tt, "core")
	tt.Key(0, ui.KeyEnter)
	if b.Model.Snapshot().Directory != filepath.Join(b.Start, "core") {
		t.Fatal(b.Model.Snapshot())
	}
	click(t, tt, "Back")
	if b.Model.Snapshot().Directory != b.Start {
		t.Fatal("back did not navigate")
	}
	click(t, tt, "Go to folder")
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type("/does-not-exist")
	tt.Key(0, ui.KeyEnter)
	if b.Model.Snapshot().Directory != b.Start || b.Model.Snapshot().Error == "" {
		t.Fatal("failed navigation lost previous listing")
	}
}

func TestDrawnFilteringAndSelectionFollowIdentity(t *testing.T) {
	b := NewDemo()
	tt := ui.NewTester(b.View, 1120, 720)
	click(t, tt, "README.md")
	if b.SelectedPath != filepath.Join(b.Start, "README.md") {
		t.Fatal(b.SelectedPath)
	}
	click(t, tt, "Sort by name")
	if b.SelectedPath != filepath.Join(b.Start, "README.md") {
		t.Fatal("sort changed selected identity")
	}
	click(t, tt, "Search this folder")
	tt.Type("cargo")
	if !tt.HasText("Cargo.toml") || tt.HasText("README.md") {
		t.Fatal(tt.Texts())
	}
	if b.SelectedPath != "" {
		t.Fatal("filtered-out selection must clear")
	}
	tt.Key(ui.Cmd, ui.KeyA)
	tt.Type("no matching entries")
	if !tt.HasText("No matching files") {
		t.Fatal(tt.Texts())
	}
}

func TestDrawnTerminalTogglePreservesContent(t *testing.T) {
	b := NewDemo()
	calls := 0
	b.Terminal = func(c *ui.Context) { calls++; ui.Text(c, "live terminal") }
	tt := ui.NewTester(b.View, 1120, 720)
	click(t, tt, "Toggle terminal")
	if !b.TerminalOpen || !tt.HasText("live terminal") {
		t.Fatal(tt.Texts())
	}
	tt.Key(ui.Cmd, ui.KeyJ)
	if b.TerminalOpen || tt.HasText("live terminal") {
		t.Fatal("terminal did not hide")
	}
	tt.Key(ui.Cmd, ui.KeyJ)
	if !b.TerminalOpen || calls < 2 {
		t.Fatal("terminal did not restore")
	}
}

func TestDrawnModesAndHiddenFiles(t *testing.T) {
	b := NewDemo()
	tt := ui.NewTester(b.View, 1120, 720)
	if tt.HasText(".gitignore") {
		t.Fatal("hidden entry initially visible")
	}
	tt.Key(ui.Cmd|ui.Shift, ui.KeyPeriod)
	if !tt.HasText(".gitignore") {
		t.Fatal(tt.Texts())
	}
	click(t, tt, "Icon view")
	if b.Mode != Icons || !tt.HasText("README.md") {
		t.Fatal("icon view lost listing")
	}
	click(t, tt, "List view")
	if b.Mode != List {
		t.Fatal("list view")
	}
}

func TestDrawnLayoutAndPalette(t *testing.T) {
	for _, dark := range []bool{false, true} {
		b := NewDemo()
		b.Dark = dark
		b.PreviewChrome = true
		tt := ui.NewTester(b.View, 1120, 720)
		for _, size := range [][2]int{{1120, 720}, {900, 560}, {1440, 900}} {
			tt.SetSize(size[0], size[1])
			back, ok := tt.Find("Back")
			if !ok {
				t.Fatal("missing navigation")
			}
			search, ok := tt.Find("Search this folder")
			if !ok || search.X < back.X+back.W || search.X+search.W > float32(size[0])+1 {
				t.Fatalf("toolbar overlap at %v: back=%+v search=%+v", size, back, search)
			}
			row, ok := tt.Find("README.md")
			if !ok || row.H < 12 || row.X < b.SidebarWidth {
				t.Fatalf("missing or clipped row %+v", row)
			}
		}
	}
}

func TestDrawnComponentSnapshots(t *testing.T) {
	out := os.Getenv("TF_DRAWN_PREVIEW")
	if out == "" {
		t.Skip("set TF_DRAWN_PREVIEW for component screenshots")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	for _, dark := range []bool{false, true} {
		b := NewDemo()
		b.Dark = dark
		b.PreviewChrome = true
		tt := ui.NewTester(b.View, 1120, 720)
		tt.SetScale(2)
		click(t, tt, "README.md")
		name := "finder-light.png"
		if dark {
			name = "finder-dark.png"
		}
		f, err := os.Create(filepath.Join(out, name))
		if err != nil {
			t.Fatal(err)
		}
		err = png.Encode(f, tt.Image())
		f.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}

func TestDrawnReservesWindowControlsAndAlignsSidebar(t *testing.T) {
	for _, bar := range []ui.TitleBar{{Height: 64, Left: 86}, {Height: 64, Right: 138}} {
		b := NewDemo()
		tt := ui.NewTester(b.View, 900, 560)
		tt.SetTitleBar(bar)
		desktop, _ := tt.Find("Desktop")
		documents, _ := tt.Find("Documents")
		if desktop.X > 60 || desktop.X != documents.X {
			t.Fatalf("sidebar labels misaligned: %+v %+v", desktop, documents)
		}
		search, _ := tt.Find("Search this folder")
		if search.X+search.W > 900-bar.Right+1 {
			t.Fatalf("search covered by native controls: %+v", search)
		}
		click(t, tt, "Hide sidebar")
		back, _ := tt.Find("Back")
		if back.X < bar.Left {
			t.Fatalf("navigation covered by native controls: %+v", back)
		}
	}
}

func TestDrawnSearchExpandsAndEscapeRestoresListing(t *testing.T) {
	b := NewDemo()
	tt := ui.NewTester(b.View, 1120, 720)
	click(t, tt, "Search this folder")
	tt.Type("cargo")
	if !tt.HasText("Cargo.toml") || tt.HasText("README.md") {
		t.Fatal(tt.Texts())
	}
	tt.Key(0, ui.KeyEscape)
	if b.Query != "" || !tt.HasText("README.md") {
		t.Fatal("Escape should dismiss the filter and restore listing")
	}
	tt.Key(ui.Cmd, ui.KeyF)
	tt.Type("README")
	if !tt.HasText("README.md") || tt.HasText("Cargo.toml") {
		t.Fatal("Find shortcut did not focus the expanded field")
	}
}

func TestModifiedDatesUseLocalCalendarAcrossYearBoundary(t *testing.T) {
	zone := time.FixedZone("test", -5*3600)
	now := time.Date(2026, 1, 1, 1, 0, 0, 0, zone)
	for _, tc := range []struct{ raw, want string }{{"2026-01-01T05:30:00Z", "Today at 00:30"}, {"2026-01-01T02:15:00Z", "Yesterday at 21:15"}, {"2025-12-28T12:00:00Z", "Dec 28, 2025 at 07:00"}, {"invalid", "—"}} {
		if got := formatModified(&tc.raw, now); got != tc.want {
			t.Errorf("%s: got %q want %q", tc.raw, got, tc.want)
		}
	}
	if formatModified(nil, now) != "—" {
		t.Fatal("missing timestamp")
	}
}

func TestTableHeaderLabelsShareBaseline(t *testing.T) {
	b := NewDemo()
	tt := ui.NewTester(b.View, 1120, 720)
	name, ok := tt.Find("Name")
	if !ok {
		t.Fatal("missing name header")
	}
	if name.X != Finder26.SidebarWidth+48 {
		t.Fatalf("main content shifted by split divider: %+v", name)
	}
	for _, label := range []string{"Date Modified", "Size", "Kind"} {
		r, found := tt.Find(label)
		if !found || r.Y != name.Y || r.H != name.H {
			t.Fatalf("header %s baseline differs: name=%+v label=%+v", label, name, r)
		}
	}
}

func TestLongBreadcrumbPreservesTerminalInput(t *testing.T) {
	b := NewDemo()
	m := b.Model.(*DemoModel)
	for _, dir := range []string{filepath.Join(os.TempDir(), "TestWindowsRenderedConPTYBidirectionalDirectoryAndStdinIsolation2193142064", "001", "中文 space ' quote"), filepath.Join(os.TempDir(), "short")} {
		m.state.Directory = dir
		b.TerminalOpen = true
		typed := ""
		b.Terminal = func(c *ui.Context) {
			ui.Box(c).Fill().Focusable().TextCaret(ui.Rect{}).Label("Terminal input probe").HandleInput(func(ev ui.InputEvent) bool {
				if ev.Kind == ui.InputText {
					typed += ev.Text
					return true
				}
				return false
			})
		}
		tt := ui.NewTester(b.View, 1120, 720)
		click(t, tt, "Terminal input probe")
		if !tt.Focused("Terminal input probe") {
			r, _ := tt.Find("Terminal input probe")
			t.Fatalf("terminal not focused: path=%s bounds=%+v", dir, r)
		}
		tt.Type("user-command")
		if typed != "user-command" {
			t.Fatalf("terminal input missing: %q", typed)
		}
	}
}
