package finderui

import (
	"github.com/egoist/mygo/ui"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"terminal-finder-mygo/internal/visualdiff"
	"testing"
)

// Probes call live component builders with the production states. Finder enables
// columns/gallery, whereas this MVP disables them: the primary report deliberately
// retains that difference rather than enabling unsupported actions for a match.
func TestCaptureFinderPixelProbes(t *testing.T) {
	out := os.Getenv("TF_PIXEL_OUTPUT")
	if out == "" {
		t.Skip("set TF_PIXEL_OUTPUT for native comparison")
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	write := func(name string, im image.Image) {
		t.Helper()
		f, e := os.Create(filepath.Join(out, name+".png"))
		if e != nil {
			t.Fatal(e)
		}
		e = png.Encode(f, im)
		f.Close()
		if e != nil {
			t.Fatal(e)
		}
	}
	palette := colors(true)
	probe := func(name string, w, h int, view func(*ui.Context)) {
		tt := ui.NewTester(func(c *ui.Context) {
			theme := *ui.DarkTheme()
			theme.Background = palette.canvas
			theme.Text = palette.text
			theme.FontSize = 13
			c.SetTheme(&theme)
			view(c)
		}, w, h)
		tt.SetScale(2)
		write(name, tt.Image())
	}
	probe("navigation", 73, 37, func(c *ui.Context) { navigationControl(c, palette, true, true) })
	probe("view-mode", 148, 37, func(c *ui.Context) { viewModeControl(c, palette, List, true) })
	probe("search", 39, 37, func(c *ui.Context) { searchControl(c, palette) })
	probe("table-header-name", 43, 26, func(c *ui.Context) {
		ui.Row(c).Fill().PaddingX(5).Children(func() { headerLabel(c, "Name", palette) })
	})
	b := NewDemo()
	b.Dark = true
	tt := ui.NewTester(b.View, 1041, 569)
	tt.SetScale(2)
	write("table-stripes", tt.Image().SubImage(image.Rect(1000, 490, 1200, 650)))
	// A native text run includes its material; both are retained in the comparison.
	// The live sidebar centers a 22pt glyph in a 32pt row. Crop its 19pt
	// reference window after layout, rather than squeezing the glyph into 19pt.
	icon := ui.NewTester(func(c *ui.Context) {
		ui.Column(c).Fill().Center().Background(palette.sidebarTop).Children(func() { glyph(c, "desktop", 22, palette.sidebarText) })
	}, 40, 32)
	icon.SetScale(2)
	write("sidebar-icon-desktop", icon.Image().SubImage(image.Rect(0, 13, 80, 51)))
	probe("sidebar-label-desktop", 71, 19, func(c *ui.Context) {
		ui.Row(c).Fill().Background(palette.sidebarTop).Children(func() { sidebarLabel(c, "Desktop", palette) })
	})
}

// A strict stored-native regression for the interior row fills. This covers no
// text, edge radius, scrollbar, or full table; those are separate audit regions.
func TestNativeFinderRowInteriorPixels(t *testing.T) {
	f, err := os.Open("testdata/finder26-dark/table-stripes.png")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	reference, err := png.Decode(f)
	if err != nil {
		t.Fatal(err)
	}
	b := NewDemo()
	b.Dark = true
	tt := ui.NewTester(b.View, 1041, 569)
	tt.SetScale(2)
	candidate := tt.Image().SubImage(image.Rect(1000, 490, 1200, 650))
	result, err := visualdiff.Compare(reference, candidate)
	if err != nil || !result.Exact {
		t.Fatalf("native row interior pixels changed: %+v, %v", result, err)
	}
}
