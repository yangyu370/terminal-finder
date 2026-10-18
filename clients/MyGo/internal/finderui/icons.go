package finderui

import "github.com/egoist/mygo/ui"

// These vectors are drawn by MyGo on every platform; none are system symbols.
func vector(body string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">` + body + `</svg>`))
}

var symbols = map[string]*ui.SVG{
	"back":     vector(`<path d="m14.5 5-7 7 7 7"/>`),
	"forward":  vector(`<path d="m9.5 5 7 7-7 7"/>`),
	"down":     vector(`<path d="m8 10 4 4 4-4"/>`),
	"up":       vector(`<path d="m8 14 4-4 4 4"/>`),
	"sidebar":  vector(`<rect x="3" y="4.5" width="18" height="15" rx="2"/><path d="M9 5v14M5.5 8h1M5.5 11h1M5.5 14h1"/>`),
	"desktop":  vector(`<rect x="2.5" y="4.5" width="19" height="14.5" rx="2.75"/><path d="M3 8h18"/><rect x="6" y="14" width="12" height="2.2" rx=".6" fill="currentColor" stroke="none"/>`),
	"document": vector(`<path d="M6 2.5h8l5 5V21H6a1 1 0 0 1-1-1V3.5a1 1 0 0 1 1-1ZM14 3v5h4.5"/>`),
	"download": vector(`<circle cx="12" cy="12" r="9"/><path d="M12 6v12m-4-5 4 5 4-5"/>`),
	"home":     vector(`<path d="m3 11 9-8 9 8M5.5 9v11h5v-6h3v6h5V9"/>`),
	"drive":    vector(`<path d="M5 4h14l3 14v2H2v-2L5 4ZM3 16h18M17 18h1M6 18h.1"/>`),
	"folder":   vector(`<path d="M3 6h7l2 2h9v12H3V6Z"/>`),
	"grid":     vector(`<rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/>`),
	"list":     vector(`<path d="M9 6h11.5M9 12h11.5M9 18h11.5"/><g fill="currentColor" stroke="none"><circle cx="3.5" cy="6" r="1.25"/><circle cx="3.5" cy="12" r="1.25"/><circle cx="3.5" cy="18" r="1.25"/></g>`),
	"columns":  vector(`<rect x="2.5" y="4.75" width="19" height="14.5" rx="1.5"/><path d="M9 4.75v14.5M15 4.75v14.5"/>`),
	"gallery":  vector(`<rect x="2.75" y="5" width="18.5" height="11" rx="1.5"/><g fill="currentColor" stroke="none"><rect x="2.75" y="18.75" width="2.4" height="2"/><rect x="6.75" y="18.75" width="2.4" height="2"/><rect x="10.75" y="18.75" width="2.4" height="2"/><rect x="14.75" y="18.75" width="2.4" height="2"/><rect x="18.75" y="18.75" width="2.4" height="2"/></g>`),
	"search":   vector(`<circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 5 5"/>`),
	"terminal": vector(`<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="m7 9 3 3-3 3m6 0h4"/>`),
	"refresh":  vector(`<path d="M20 9a8 8 0 1 0 .2 6M20 4v5h-5"/>`),
	"more":     vector(`<circle cx="12" cy="12" r="9"/><path d="M7 12h.1M12 12h.1M17 12h.1" stroke-width="2.7"/>`),
	"sun":      vector(`<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5l1.5 1.5M5 19l1.5-1.5M17.5 6.5l1.5-1.5"/>`),
	"moon":     vector(`<path d="M20.5 14A9 9 0 0 1 10 3.5 9 9 0 1 0 20.5 14Z"/>`),
	"close":    vector(`<path d="m7 7 10 10M17 7 7 17"/>`),
	"clock":    vector(`<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>`),
	"check":    vector(`<path d="m5 12 4 4L19 6"/>`),
}
var folderImage = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="64" height="56" viewBox="0 0 64 56"><defs><linearGradient id="back" x2="0" y2="1"><stop stop-color="#63c7f7"/><stop offset="1" stop-color="#269bd7"/></linearGradient><linearGradient id="front" x2="0" y2="1"><stop stop-color="#83d9fb"/><stop offset="1" stop-color="#43afe5"/></linearGradient></defs><path d="M4 11a4 4 0 0 1 4-4h17l6 6h25a4 4 0 0 1 4 4v30a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4Z" fill="url(#back)" stroke="#168bc7" stroke-width=".7"/><path d="M4 21a4 4 0 0 1 4-4h48a4 4 0 0 1 4 4v26a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4Z" fill="url(#front)" stroke="#2e9ed7" stroke-width=".7"/><path d="M8 18h48" stroke="#c6f0ff" stroke-opacity=".8"/></svg>`))
var documentImage = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="48" height="56" viewBox="0 0 48 56"><defs><linearGradient id="paper" x2="0" y2="1"><stop stop-color="#fff"/><stop offset="1" stop-color="#edf0f3"/></linearGradient></defs><path d="M7 2h23l12 12v38a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2Z" fill="url(#paper)" stroke="#aeb5bd"/><path d="M30 2v12h12" fill="#e2e7ee" stroke="#aeb5bd"/><path d="M12 25h22M12 30h22M12 35h22M12 40h16" stroke="#b1bdca" stroke-width="2"/></svg>`))

func glyph(c *ui.Context, name string, size float32, color ui.Color) ui.Element {
	s := symbols[name]
	if s == nil {
		s = symbols["document"]
	}
	x, y := float32(0), float32(0)
	if size == Finder26.ToolbarGlyph {
		switch name {
		case "grid":
			size = 21
			x = 0
			y = -.25
		case "list":
			size = 21
			x = -.25
			y = .25
		case "columns":
			size = 22.5
			x = 1
			y = 0
		case "gallery":
			size = 22.5
			x = .25
			y = -.25
		case "search":
			size = 21.5
			x = .25
			y = -.25
		case "desktop":
			x = 1.5
		case "back":
			x = 0
		}
	}
	return ui.Icon(c, s).Size(size, size).Shrink(0).TextColor(color).Left(x).Top(y)
}

var shellImage = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="56" height="56" viewBox="0 0 56 56"><defs><linearGradient id="t" x2="0" y2="1"><stop stop-color="#474d56"/><stop offset="1" stop-color="#20242c"/></linearGradient></defs><rect x="4" y="5" width="48" height="46" rx="8" fill="url(#t)" stroke="#13171c"/><path d="M9 7h38" stroke="#7a818b" stroke-opacity=".6"/><path d="m13 19 9 8-9 8m14 1h13" fill="none" stroke="#d8e6ed" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>`))
var sourceImage = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="48" height="56" viewBox="0 0 48 56"><defs><linearGradient id="p" x2="0" y2="1"><stop stop-color="#fff"/><stop offset="1" stop-color="#edf2f7"/></linearGradient></defs><path d="M7 2h23l12 12v38a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2Z" fill="url(#p)" stroke="#aab8c7"/><path d="M30 2v12h12" fill="#dce6ef" stroke="#aab8c7"/><path d="m18 25-7 7 7 7m12-14 7 7-7 7m-7 4 3-22" fill="none" stroke="#4e8cb6" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>`))
var markdownImage = ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" width="48" height="56" viewBox="0 0 48 56"><defs><linearGradient id="p" x2="0" y2="1"><stop stop-color="#fff"/><stop offset="1" stop-color="#edf0f3"/></linearGradient></defs><path d="M7 2h23l12 12v38a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2Z" fill="url(#p)" stroke="#aeb5bd"/><path d="M30 2v12h12" fill="#e0e7ed" stroke="#aeb5bd"/><path d="M11 22h23M11 27h23M11 32h14" stroke="#b4bec8" stroke-width="2"/><rect x="9" y="37" width="30" height="12" rx="2" fill="#5c85ab"/><path d="M13 46v-6l4 4 4-4v6m9-6v6m-3-3 3 3 3-3" fill="none" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>`))
