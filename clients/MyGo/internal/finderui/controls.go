package finderui

import "github.com/egoist/mygo/ui"

// These builders are shared by the live toolbar and pixel probes. Rendering a
// probe cannot silently change button geometry or support for an action.
func navigationControl(c *ui.Context, p palette, backDisabled, forwardDisabled bool) (back, forward bool) {
	capsule(c, p, func() {
		back = iconButton(c, "Back", "back", p, false, backDisabled).Size(34, 34).Clicked()
		ui.Box(c).Size(1, 20).Background(p.stripe)
		forward = iconButton(c, "Forward", "forward", p, false, forwardDisabled).Size(34, 34).Clicked()
	})
	return
}

func viewModeControl(c *ui.Context, p palette, mode ViewMode, extended bool) ViewMode {
	capsule(c, p, func() {
		if iconButton(c, "Icon view", "grid", p, mode == Icons, false).Clicked() {
			mode = Icons
		}
		if iconButton(c, "List view", "list", p, mode == List, false).Clicked() {
			mode = List
		}
		if extended {
			iconButton(c, "Column view (not in this sample)", "columns", p, false, true)
			iconButton(c, "Gallery view (not in this sample)", "gallery", p, false, true).Draw(func(painter *ui.Painter, r ui.Rect) {
				painter.Fill(ui.Rect{X: r.X + 2, Y: r.Y + 7, W: .75, H: 20}, p.stripe, 0)
			})
		}
	})
	return mode
}

func searchControl(c *ui.Context, p palette) (clicked bool) {
	capsule(c, p, func() {
		clicked = iconButton(c, "Search this folder", "search", p, false, false).Size(34, 34).Clicked()
	})
	return
}
