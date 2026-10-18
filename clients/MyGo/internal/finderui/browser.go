package finderui

import (
	"fmt"
	"github.com/egoist/mygo/ui"
	"path/filepath"
	"strings"
	"terminal-finder-mygo/internal/backend"
	"terminal-finder-mygo/internal/workspace"
)

type Browser struct {
	searchOpen, searchFocus    bool
	Model                      Navigator
	Home, Start                string
	Terminal                   func(*ui.Context)
	FocusTerminal              func()
	OpenFile                   func(string)
	SelectedPath               string
	Query                      string
	Hidden, Dark, TerminalOpen bool
	Mode                       ViewMode
	SidebarWidth               float32
	// PreviewChrome draws noninteractive traffic lights only in exported component images.
	PreviewChrome        bool
	sidebarOpen          bool
	browserPercent       float32
	rows                 ui.ListState
	descending, sortDate bool
	lastDirectory        string
	pathOpen, pathFocus  bool
	pathDraft            string
}

// MyGo Split adds its own 1pt divider after the pane. The measured sidebar
// span includes that divider, so its pane is one point narrower.
func New(model Navigator, home, start string) *Browser {
	return &Browser{Model: model, Home: home, Start: start, SidebarWidth: Finder26.SidebarWidth - 1, sidebarOpen: true, browserPercent: 62}
}

type palette struct{ canvas, toolbarTop, toolbarBottom, sidebarTop, sidebarBottom, text, muted, line, stripe, hover, selection, sideSelection, control, controlLine, sidebarText, titleText, symbol, controlSelection, selectedSymbol ui.Color }

func colors(dark bool) palette {
	if dark {
		return palette{canvas: ui.Hex("#262626"), toolbarTop: ui.Hex("#262626"), toolbarBottom: ui.Hex("#262626"), sidebarTop: ui.Hex("#181818"), sidebarBottom: ui.Hex("#1c1c1c"), text: ui.Hex("#dedede"), muted: ui.Hex("#999999"), line: ui.Hex("#414144"), stripe: ui.Hex("#303030"), hover: ui.Hex("#37373b"), selection: ui.Hex("#255eb8"), sideSelection: ui.Hex("#444449"), control: ui.Hex("#1c1c1c"), controlLine: ui.Hex("#3b3b3b"), sidebarText: ui.Hex("#f4f4f4"), titleText: ui.Hex("#e9e9e9"), symbol: ui.Hex("#e8e8e8"), controlSelection: ui.Hex("#3f3f3f"), selectedSymbol: ui.Hex("#ebebeb")}
	}
	return palette{canvas: ui.Hex("#ffffff"), toolbarTop: ui.Hex("#f8f8f9"), toolbarBottom: ui.Hex("#f0f0f2"), sidebarTop: ui.Hex("#eeedf1"), sidebarBottom: ui.Hex("#e4e3e9"), text: ui.Hex("#2b2b2f"), muted: ui.Hex("#818187"), line: ui.Hex("#d8d8db"), stripe: ui.Hex("#f3f3f5"), hover: ui.Hex("#dedde3"), selection: ui.Hex("#0064db"), sideSelection: ui.Hex("#d6d5dd"), control: ui.Hex("#fdfdfd"), controlLine: ui.Hex("#d6d6da"), sidebarText: ui.Hex("#262626"), titleText: ui.Hex("#262626"), symbol: ui.Hex("#404040"), controlSelection: ui.Hex("#d6d5dd"), selectedSymbol: ui.Hex("#404040")}
}
func (b *Browser) View(c *ui.Context) {
	width, _ := c.Size()
	b.SidebarWidth = max(168, min(min(320, width-c.TitleBar().Right-560), b.SidebarWidth))
	b.browserPercent = max(30, min(80, b.browserPercent))
	p := colors(b.Dark)
	theme := *ui.LightTheme()
	if b.Dark {
		theme = *ui.DarkTheme()
	}
	theme.Background = p.canvas
	theme.Surface = p.control
	theme.Text = p.text
	theme.TextMuted = p.muted
	theme.Border = ui.Transparent
	theme.Accent = p.selection
	theme.SurfaceHover = p.hover
	theme.Radius = 8
	theme.FontSize = 13
	theme.Spacing = 3
	c.SetTheme(&theme)
	s := b.Model.Snapshot()
	if c.Shortcut(ui.Cmd, ui.KeyF) {
		b.searchOpen = true
		b.searchFocus = true
	}
	if s.Directory != b.lastDirectory {
		b.SelectedPath = ""
		b.Query = ""
		b.searchOpen = false
		b.lastDirectory = s.Directory
	}
	if c.Shortcut(ui.Cmd, ui.KeyJ) {
		b.toggleTerminal()
	}
	if c.Shortcut(ui.Cmd|ui.Shift, ui.KeyPeriod) {
		b.Hidden = !b.Hidden
	}
	if c.Shortcut(ui.Cmd, ui.KeyL) || c.Shortcut(ui.Cmd|ui.Shift, ui.KeyG) {
		b.openPath(s.Directory)
	}
	if c.Shortcut(ui.Cmd, ui.KeyBracketLeft) {
		b.Model.Back()
	}
	if c.Shortcut(ui.Cmd, ui.KeyBracketRight) {
		b.Model.Forward()
	}
	if c.Shortcut(ui.Cmd, ui.KeyUp) {
		b.Model.Navigate(filepath.Dir(s.Directory))
	}
	if c.Shortcut(ui.Cmd, ui.KeyR) {
		b.Model.Refresh()
	}
	if c.Shortcut(ui.Cmd, ui.Key1) {
		b.Mode = Icons
	}
	if c.Shortcut(ui.Cmd, ui.Key2) {
		b.Mode = List
	}
	rows := b.entries(s)
	found := false
	for _, e := range rows {
		if e.Path == b.SelectedPath {
			found = true
		}
	}
	if !found {
		b.SelectedPath = ""
	}
	ui.Row(c).Fill().Gap(0).FontSize(13).TextColor(p.text).Children(func() {
		if b.sidebarOpen {
			ui.Split(c, &b.SidebarWidth, func() { b.sidebar(c, p, s) }, func() { b.main(c, p, s, rows) }).Fill()
		} else {
			b.main(c, p, s, rows)
		}
	})
	b.pathDialog(c, p, s)
}
func (b *Browser) main(c *ui.Context, p palette, s workspace.Snapshot, rows []backend.Entry) {
	ui.Column(c).Fill().Gap(0).MinWidth(0).Children(func() {
		b.toolbar(c, p, s)
		if s.Error != "" {
			ui.Row(c).Padding(7, 16).Background(ui.Hex("#fff0d5")).Children(func() {
				ui.Text(c, s.Error).FontSize(12).TextColor(ui.Hex("#80510b")).Grow(1)
				if iconButton(c, "Dismiss error", "close", p, false, false).Clicked() {
					b.Model.Refresh()
				}
			})
		}
		if b.TerminalOpen && b.Terminal != nil {
			ui.SplitVerticalPercent(c, &b.browserPercent, func() { b.files(c, p, s, rows) }, func() { b.terminal(c, p, s) }).Grow(1).MinHeight(0)
		} else {
			b.files(c, p, s, rows)
		}
	})
}
func iconButton(c *ui.Context, label, name string, p palette, selected, disabled bool) ui.Element {
	button := ui.ButtonBase(c.Key(label)).Size(Finder26.ButtonWidth, Finder26.ButtonHeight).Padding(6).Radius(17).Label(label).Tooltip(label).Disabled(disabled)
	if selected {
		button.Draw(func(painter *ui.Painter, r ui.Rect) {
			w, h := min(r.W, 34), min(r.H, 28)
			painter.Fill(ui.Rect{X: r.X + (r.W-w)/2, Y: r.Y + (r.H-h)/2, W: w, H: h}, p.controlSelection, h/2)
		})
	} else if button.Pressed() {
		button.Background(p.sideSelection)
	} else if button.Hovered() {
		button.Background(p.hover)
	}
	if disabled {
		button.Opacity(.635)
	}
	symbol := p.symbol
	if selected {
		symbol = p.selectedSymbol
	}
	button.Children(func() { glyph(c, name, Finder26.ToolbarGlyph, symbol) })
	return button
}
func capsule(c *ui.Context, p palette, fn func()) {
	// Paint the bezel without Element.Border: a layout border adds width to the
	// intrinsic group and shifts every segment by 1.5 device pixels at 2x.
	ui.Row(c).Height(Finder26.CapsuleHeight).Padding(1, 2).Gap(0).Radius(18).Background(p.control).Shadow(0, 1, 2, 0, ui.RGBA(0, 0, 0, .035)).Draw(func(painter *ui.Painter, r ui.Rect) {
		painter.Stroke(r, p.controlLine, 18, .75)
	}).Children(fn)
}
func (b *Browser) toolbar(c *ui.Context, p palette, s workspace.Snapshot) {
	ui.Row(c).Height(Finder26.ToolbarHeight).Shrink(0).Padding(0, 8).Gap(12).Gradient(p.toolbarTop, p.toolbarBottom, 180).DragWindow().Children(func() {
		if !b.sidebarOpen {
			if left := c.TitleBar().Left; left > 0 {
				ui.Box(c).Width(left).Shrink(0)
			}
			if iconButton(c, "Show sidebar", "sidebar", p, false, false).Clicked() {
				b.sidebarOpen = true
			}
		}
		back, forward := navigationControl(c, p, !s.CanBack, !s.CanForward)
		if back {
			b.Model.Back()
		}
		if forward {
			b.Model.Forward()
		}
		title := ui.ButtonBase(c.Key("location-title")).Justify(ui.Start).Grow(1).Basis(0).MinWidth(60).Height(34).PaddingX(1).Label("Go to folder").Radius(7)
		if title.Hovered() {
			title.Background(p.hover)
		}
		title.Children(func() {
			ui.Text(c, filepath.Base(s.Directory)).FontSize(Finder26.TitleFont).FontWeight(600).TextColor(p.titleText).SingleLine()
		})
		if title.Clicked() {
			b.openPath(s.Directory)
		}
		width, _ := c.Size()
		extended := width-c.TitleBar().Right > 1000 && !b.searchOpen
		b.Mode = viewModeControl(c, p, b.Mode, extended)
		capsule(c, p, func() {
			if iconButton(c, "Refresh", "refresh", p, false, s.Loading).Clicked() {
				b.Model.Refresh()
			}
			if iconButton(c, "Toggle terminal", "terminal", p, b.TerminalOpen, false).Clicked() {
				b.toggleTerminal()
			}
			moon := "moon"
			if b.Dark {
				moon = "sun"
			}
			if iconButton(c, "Switch appearance", moon, p, false, false).Clicked() {
				b.Dark = !b.Dark
			}
		})
		if b.searchOpen {
			searchWidth := float32(164)
			if width, _ := c.Size(); width-c.TitleBar().Right < 1000 {
				searchWidth = 128
			}
			ui.Row(c).Width(searchWidth).Height(34).Padding(0, 10).Gap(6).Radius(17).Background(p.control).Border(.8, p.controlLine).Children(func() {
				glyph(c, "search", 15, p.muted)
				field := ui.TextInput(c.Key("search-input"), &b.Query).Label("Search this folder").Placeholder("Search").Grow(1).MinWidth(0).Padding(0).Height(28).Border(0, ui.Transparent).Background(ui.Transparent).FontSize(12).FocusRing(false)
				if b.searchFocus {
					field.Focus()
					b.searchFocus = false
				}
				if field.Shortcut(0, ui.KeyEscape) {
					b.Query = ""
					b.searchOpen = false
					b.rows.Focus(c)
				}
			})
		} else {
			if searchControl(c, p) {
				b.searchOpen = true
				b.searchFocus = true
			}
		}
		if right := c.TitleBar().Right; right > 0 {
			ui.Box(c).Width(right).Shrink(0)
		}
	})
}
func (b *Browser) sidebar(c *ui.Context, p palette, s workspace.Snapshot) {
	ui.Column(c).Fill().Padding(8, 0, 8, 8).Background(p.toolbarBottom).Children(func() {
		ui.Column(c).Fill().Gap(0).Radius(Finder26.SidebarRadius).Gradient(p.sidebarTop, p.sidebarBottom, 160).Border(.75, p.controlLine).Shadow(0, 1, 4, 0, ui.RGBA(0, 0, 0, .06)).Label("Sidebar panel").Clip().Children(func() {
			ui.Row(c).Height(48).Shrink(0).Padding(0, 10).DragWindow().Children(func() {
				if b.PreviewChrome {
					for _, color := range []string{"#ff5f57", "#febc2e", "#28c840"} {
						ui.Box(c).Size(12, 12).Radius(6).Background(ui.Hex(color)).Border(.5, ui.RGBA(0, 0, 0, .13)).Margin(0, 7, 0, 0)
					}
				}
				ui.Spacer(c)
				if iconButton(c, "Hide sidebar", "sidebar", p, false, false).Size(24, 26).Padding(4).Clicked() {
					b.sidebarOpen = false
				}
			})
			ui.Scroll(c).Grow(1).MinHeight(0).Padding(12, 8, 12, 9).Children(func() {
				b.section(c, p, "Favorites")
				b.place(c, p, s, "Desktop", "desktop", filepath.Join(b.Home, "Desktop"))
				b.place(c, p, s, "Documents", "document", filepath.Join(b.Home, "Documents"))
				b.place(c, p, s, "Downloads", "download", filepath.Join(b.Home, "Downloads"))
				b.place(c, p, s, "Workspace", "folder", b.Start)
				ui.Box(c).Height(22)
				b.section(c, p, "Locations")
				b.place(c, p, s, filepath.Base(b.Home), "home", b.Home)
				root := filepath.VolumeName(s.Directory) + string(filepath.Separator)
				b.place(c, p, s, "Computer", "drive", root)
			})
		})
	})
}
func (b *Browser) section(c *ui.Context, p palette, title string) {
	ui.Text(c, title).FontSize(11).FontWeight(600).TextColor(p.muted).Padding(0, 10, 7)
}
func (b *Browser) place(c *ui.Context, p palette, s workspace.Snapshot, name, symbol, path string) {
	button := ui.ButtonBase(c.Key("place:"+name)).Justify(ui.Start).Height(32).Padding(0, 6).Gap(8).Radius(10).Label("Open " + name)
	active := filepath.Clean(s.Directory) == filepath.Clean(path)
	if active {
		button.Background(p.sideSelection)
	} else if button.Hovered() {
		button.Background(p.hover)
	}
	button.Children(func() {
		glyph(c, symbol, 22, p.sidebarText)
		sidebarLabel(c, name, p).SingleLine()
	})
	if button.Clicked() {
		b.Query = ""
		b.Model.Navigate(path)
	}
}
func (b *Browser) files(c *ui.Context, p palette, s workspace.Snapshot, rows []backend.Entry) {
	ui.Column(c).Fill().MinHeight(0).Gap(0).Background(p.canvas).Children(func() {
		if b.Mode == List {
			b.table(c, p, rows)
		} else {
			b.grid(c, p, rows)
		}
		b.pathbar(c, p, s.Directory)
		ui.Row(c).Height(24).Shrink(0).Center().Background(p.toolbarBottom).BorderWidth(1, 0, 0, 0).BorderColor(p.line).Children(func() {
			count := fmt.Sprintf("%d items", len(rows))
			if len(rows) == 1 {
				count = "1 item"
			}
			if b.SelectedPath != "" {
				count = fmt.Sprintf("1 of %d selected", len(rows))
			}
			if s.Loading {
				count = "Opening folder…"
			}
			ui.Text(c, count).FontSize(11).TextColor(p.muted)
		})
	})
}
func (b *Browser) table(c *ui.Context, p palette, rows []backend.Entry) {
	ui.Row(c).Height(Finder26.HeaderHeight).Shrink(0).Gap(0).AlignItems(ui.Start).Background(p.toolbarBottom).Children(func() {
		header := ui.ButtonBase(c).Grow(1).Basis(0).Height(26).Label("Sort by name").Padding(0, 8, 0, 48).BorderWidth(0, 1, 0, 0).BorderColor(p.line)
		header.Children(func() {
			headerLabel(c, "Name", p).Grow(1)
			if !b.sortDate {
				arrow := "up"
				if b.descending {
					arrow = "down"
				}
				glyph(c, arrow, 12, p.muted)
			}
		})
		if header.Clicked() {
			if !b.sortDate {
				b.descending = !b.descending
			}
			b.sortDate = false
		}
		h := ui.ButtonBase(c).Justify(ui.Start).Width(Finder26.DateWidth).Height(26).PaddingX(8).Label("Sort by date").BorderWidth(0, 1, 0, 0).BorderColor(p.line)
		h.Children(func() { headerLabel(c, "Date Modified", p) })
		if h.Clicked() {
			if b.sortDate {
				b.descending = !b.descending
			}
			b.sortDate = true
		}
		ui.Row(c).Width(Finder26.SizeWidth).Height(26).PaddingX(8).BorderWidth(0, 1, 0, 0).BorderColor(p.line).Children(func() { headerLabel(c, "Size", p) })
		ui.Row(c).Width(Finder26.KindWidth).Height(26).PaddingX(8).Children(func() { headerLabel(c, "Kind", p) })
	})
	selected := -1
	for i, e := range rows {
		if e.Path == b.SelectedPath {
			selected = i
		}
	}
	b.rows.Selected = &selected
	b.rows.Key = func(i int) any { return rows[i].Path }
	b.rows.Label = func(i int) string { return rows[i].Name }
	list := ui.List(c, &b.rows, len(rows)).Grow(1).MinHeight(0).Padding(Finder26.RowTopInset, Finder26.RowInset).FocusRing(false).Draw(func(painter *ui.Painter, r ui.Rect) {
		for i := 1; float32(i)*Finder26.RowHeight < r.H; i += 2 {
			y := r.Y + Finder26.RowTopInset + float32(i)*Finder26.RowHeight
			painter.Fill(ui.Rect{X: r.X + Finder26.RowInset, Y: y, W: r.W - 2*Finder26.RowInset, H: min(Finder26.RowHeight, r.Y+r.H-y)}, p.stripe, Finder26.RowRadius)
		}
	}).Rows(func(r ui.ListRow) {
		e := rows[r.Index]
		color, secondary := p.text, p.muted
		fill := ui.Transparent
		if r.Index%2 == 1 {
			fill = p.stripe
		}
		if r.Selected() {
			if r.ListFocused() {
				fill = p.selection
				color = ui.Hex("#ffffff")
				secondary = ui.Hex("#e4edff")
			} else {
				fill = p.sideSelection
			}
		}
		ui.Row(r.Context).Height(Finder26.RowHeight).Radius(Finder26.RowRadius).Padding(0, 5).Background(fill).Gap(0).TextColor(color).Children(func() {
			ui.Row(r.Context).Grow(1).Basis(0).MinWidth(0).Gap(4).Children(func() {
				if e.IsDirectory {
					glyph(r.Context, "forward", 8, secondary)
				} else {
					ui.Box(r.Context).Width(8)
				}
				fileIcon(r.Context, e, 16)
				ui.Text(r.Context, e.Name).FontSize(Finder26.BodyFont).SingleLine().Grow(1).MinWidth(0)
			})
			ui.Text(r.Context, modified(e.ModifiedAt)).Width(Finder26.DateWidth).PaddingX(8).FontSize(Finder26.MetadataFont).TextColor(secondary).SingleLine()
			ui.Text(r.Context, size(e)).Width(Finder26.SizeWidth).PaddingX(10).FontSize(Finder26.MetadataFont).TextColor(secondary).TextAlign(ui.End).SingleLine()
			ui.Text(r.Context, kind(e)).Width(Finder26.KindWidth - 15).PaddingX(8).FontSize(Finder26.MetadataFont).TextColor(secondary).SingleLine()
		})
	})
	if list.Changed() {
		if selected >= 0 && selected < len(rows) {
			b.SelectedPath = rows[selected].Path
		}
	}
	if list.Submitted() && selected >= 0 && selected < len(rows) {
		b.activate(rows[selected])
	}
	if len(rows) == 0 {
		ui.Column(c).Absolute().Left(0).Right(0).Top(85).AlignItems(ui.Center).Gap(8).Children(func() {
			glyph(c, "search", 30, p.muted)
			text := "This folder is empty"
			if b.Query != "" {
				text = "No matching files"
			}
			ui.Text(c, text).FontSize(14).TextColor(p.muted)
		})
	}
}
func fileIcon(c *ui.Context, e backend.Entry, size float32) {
	img := documentImage
	if e.IsDirectory {
		img = folderImage
	} else {
		switch strings.ToLower(filepath.Ext(e.Name)) {
		case ".sh":
			img = shellImage
		case ".go", ".rs", ".toml", ".mod":
			img = sourceImage
		case ".md":
			img = markdownImage
		}
	}
	ui.Image(c, img).Size(size, size).Shrink(0)
}
func (b *Browser) grid(c *ui.Context, p palette, rows []backend.Entry) {
	ui.Scroll(c).Grow(1).MinHeight(0).Padding(20).Children(func() {
		ui.Row(c).Wrap().Gap(12).Children(func() {
			for _, e := range rows {
				tile := ui.ButtonBase(c.Key(e.Path)).Column().Width(104).Height(104).Padding(8, 4).Gap(8).AlignItems(ui.Center).Radius(6).Label(e.Name)
				if b.SelectedPath == e.Path {
					tile.Background(p.sideSelection)
				} else if tile.Hovered() {
					tile.Background(p.stripe)
				}
				tile.Children(func() { fileIcon(c, e, 54); ui.Text(c, e.Name).FontSize(12).MaxLines(2).TextAlign(ui.Center) })
				if tile.Clicked() {
					b.SelectedPath = e.Path
				}
				if tile.DoubleClicked() || tile.Shortcut(0, ui.KeyEnter) {
					b.activate(e)
				}
			}
		})
		if len(rows) == 0 {
			ui.Text(c, "No matching files").TextColor(p.muted).Padding(30)
		}
	})
}
func (b *Browser) activate(e backend.Entry) {
	if e.IsDirectory {
		b.Query = ""
		b.Model.Navigate(e.Path)
	} else if b.OpenFile != nil {
		b.OpenFile(e.Path)
	}
}
func (b *Browser) pathbar(c *ui.Context, p palette, path string) {
	ui.Row(c).Height(29).Shrink(0).Padding(0, 14).Gap(5).Background(p.toolbarTop).BorderWidth(1, 0, 0, 0).BorderColor(p.line).Clip().Children(func() {
		parts := breadcrumbs(path)
		// Preserve the location at narrow widths; intermediate ancestors remain available through Go to folder.
		if len(parts) > 5 {
			parts = append(parts[:1], parts[len(parts)-4:]...)
		}
		for i, part := range parts {
			if i > 0 {
				glyph(c, "forward", 9, p.muted)
			}
			item := ui.ButtonBase(c.Key(part.path)).Justify(ui.Start).Height(25).PaddingX(2).Gap(4).Radius(3).Shrink(1).Label("Navigate to " + part.path)
			if item.Hovered() {
				item.Background(p.hover)
			}
			item.Children(func() {
				symbol := "folder"
				if i == 0 {
					symbol = "drive"
				}
				glyph(c, symbol, 12, p.muted)
				ui.Text(c, part.name).FontSize(11).TextColor(p.muted).SingleLine()
			})
			if item.Clicked() {
				b.Model.Navigate(part.path)
			}
		}
	})
}
func (b *Browser) terminal(c *ui.Context, p palette, s workspace.Snapshot) {
	ui.Column(c).Fill().Gap(0).Background(ui.Hex("#1e1e20")).Children(func() {
		ui.Row(c).Height(30).Shrink(0).Padding(0, 14).Gap(7).Background(ui.Hex("#2a2a2d")).Children(func() {
			glyph(c, "terminal", 13, ui.Hex("#b4b4ba"))
			ui.Text(c, "Terminal").FontSize(11).TextColor(ui.Hex("#c1c1c6"))
			ui.Text(c, "— "+filepath.Base(s.Directory)).FontSize(11).TextColor(ui.Hex("#89898e"))
			ui.Spacer(c)
			col := ui.Hex("#c4a36c")
			if s.Sync == "Synced" {
				col = ui.Hex("#80b792")
			}
			ui.Box(c).Size(5, 5).Radius(3).Background(col)
			ui.Text(c, s.Sync).FontSize(10).TextColor(col)
			if iconButton(c, "Close terminal", "close", colors(true), false, false).Size(21, 21).Clicked() {
				b.TerminalOpen = false
			}
		})
		ui.Column(c).Grow(1).MinHeight(0).Padding(7, 12).Children(func() { b.Terminal(c) })
	})
}
func (b *Browser) toggleTerminal() {
	b.TerminalOpen = !b.TerminalOpen
	if b.TerminalOpen && b.FocusTerminal != nil {
		b.FocusTerminal()
	}
}
func (b *Browser) openPath(path string) { b.pathDraft = path; b.pathOpen = true; b.pathFocus = true }
func (b *Browser) pathDialog(c *ui.Context, p palette, s workspace.Snapshot) {
	ui.Modal(c, &b.pathOpen, func() {
		ui.Column(c).Width(480).Padding(22).Gap(14).Radius(12).Background(p.toolbarTop).Border(1, p.line).Shadow(0, 12, 40, 0, ui.RGBA(0, 0, 0, .2)).Children(func() {
			ui.Text(c, "Go to folder").FontSize(14).FontWeight(600)
			field := ui.TextInput(c, &b.pathDraft).Label("Folder path").Height(32).Padding(6, 9).FontSize(13).Border(1, p.controlLine)
			if b.pathFocus {
				field.Focus()
				b.pathFocus = false
			}
			goTo := field.Submitted()
			ui.Row(c).Gap(8).Children(func() {
				ui.Spacer(c)
				if ui.Button(c, "Cancel").Width(80).Clicked() {
					b.pathOpen = false
				}
				if ui.PrimaryButton(c, "Go").Width(80).Disabled(strings.TrimSpace(b.pathDraft) == "").Clicked() {
					goTo = true
				}
			})
			if goTo && strings.TrimSpace(b.pathDraft) != "" {
				path := strings.TrimSpace(b.pathDraft)
				if path == "~" {
					path = b.Home
				} else if strings.HasPrefix(path, "~/") {
					path = filepath.Join(b.Home, path[2:])
				}
				if !filepath.IsAbs(path) {
					path = filepath.Join(s.Directory, path)
				}
				b.Model.Navigate(path)
				b.pathOpen = false
			}
		})
	})
}

// The supplied reference puts these text runs 0.5pt above the generic MyGo
// line box. This calibration is shared by probes and live labels.
func headerLabel(c *ui.Context, text string, p palette) ui.Element {
	color := p.muted
	if p.canvas == ui.Hex("#262626") {
		color = ui.Hex("#9c9c9c")
	}
	return ui.Text(c, text).FontSize(Finder26.HeaderFont).FontWeight(400).TextColor(color).Top(-.5)
}
func sidebarLabel(c *ui.Context, text string, p palette) ui.Element {
	return ui.Text(c, text).FontSize(Finder26.SidebarFont).TextColor(p.sidebarText).Top(-.5)
}
