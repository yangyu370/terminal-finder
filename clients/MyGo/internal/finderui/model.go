// Package finderui draws a Finder-style shell using only MyGo elements and vectors.
package finderui

import (
	"fmt"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"terminal-finder-mygo/internal/backend"
	"terminal-finder-mygo/internal/workspace"
	"time"
)

type Navigator interface {
	Snapshot() workspace.Snapshot
	Navigate(string)
	Back()
	Forward()
	Refresh()
}
type ViewMode int

const (
	List ViewMode = iota
	Icons
)

func (b *Browser) entries(s workspace.Snapshot) []backend.Entry {
	rows := make([]backend.Entry, 0, len(s.Entries))
	for _, e := range s.Entries {
		if !b.Hidden && strings.HasPrefix(e.Name, ".") {
			continue
		}
		if b.Query != "" && !strings.Contains(strings.ToLower(e.Name), strings.ToLower(b.Query)) {
			continue
		}
		rows = append(rows, e)
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, z := rows[i], rows[j]
		if a.IsDirectory != z.IsDirectory {
			return a.IsDirectory
		}
		cmp := strings.Compare(strings.ToLower(a.Name), strings.ToLower(z.Name))
		if b.sortDate {
			av, zv := "", ""
			if a.ModifiedAt != nil {
				av = *a.ModifiedAt
			}
			if z.ModifiedAt != nil {
				zv = *z.ModifiedAt
			}
			if av != zv {
				cmp = strings.Compare(av, zv)
			}
		}
		if b.descending {
			return cmp > 0
		}
		return cmp < 0
	})
	return rows
}
func size(e backend.Entry) string {
	if e.IsDirectory || e.Size == nil {
		return "—"
	}
	n := float64(*e.Size)
	for _, unit := range []string{"bytes", "KB", "MB", "GB", "TB"} {
		if n < 1000 || unit == "TB" {
			if unit == "bytes" {
				return fmt.Sprintf("%.0f bytes", n)
			}
			return fmt.Sprintf("%.0f %s", n, unit)
		}
		n /= 1000
	}
	return "—"
}
func kind(e backend.Entry) string {
	if e.IsDirectory {
		return "Folder"
	}
	switch strings.ToLower(filepath.Ext(e.Name)) {
	case ".md":
		return "Markdown document"
	case ".go":
		return "Go source"
	case ".rs":
		return "Rust source"
	case ".toml":
		return "TOML document"
	case ".sh":
		return "Shell script"
	case ".png", ".jpg", ".jpeg":
		return "Image"
	case ".zip":
		return "ZIP archive"
	}
	return "Document"
}
func modified(raw *string) string { return formatModified(raw, time.Now()) }
func formatModified(raw *string, now time.Time) string {
	if raw == nil {
		return "—"
	}
	parsed, err := time.Parse(time.RFC3339, *raw)
	if err != nil {
		return "—"
	}
	local := parsed.In(now.Location())
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if !local.Before(today) && local.Before(today.AddDate(0, 0, 1)) {
		return "Today at " + local.Format("15:04")
	}
	if !local.Before(today.AddDate(0, 0, -1)) && local.Before(today) {
		return "Yesterday at " + local.Format("15:04")
	}
	return local.Format("Jan 2, 2006 at 15:04")
}

type crumb struct{ name, path string }

func breadcrumbs(path string) []crumb {
	path = filepath.Clean(path)
	volume := filepath.VolumeName(path)
	root := volume + string(filepath.Separator)
	out := []crumb{{"Computer", root}}
	tail := strings.TrimPrefix(path, root)
	for _, name := range strings.Split(tail, string(filepath.Separator)) {
		if name == "" || name == "." {
			continue
		}
		root = filepath.Join(root, name)
		out = append(out, crumb{name, root})
	}
	return out
}

// DemoModel is deterministic component-preview data. Production uses the Rust controller.
type DemoModel struct {
	state   workspace.Snapshot
	folders map[string][]backend.Entry
	history []string
	at      int
}

func (m *DemoModel) Snapshot() workspace.Snapshot {
	s := m.state
	s.Entries = append([]backend.Entry(nil), s.Entries...)
	return s
}
func (m *DemoModel) Navigate(path string) {
	path = filepath.Clean(path)
	rows, ok := m.folders[path]
	if !ok {
		m.state.Error = "The folder could not be opened."
		return
	}
	if path != m.state.Directory {
		m.history = append(m.history[:m.at+1], path)
		m.at++
	}
	m.set(path, rows)
}
func (m *DemoModel) set(path string, rows []backend.Entry) {
	m.state = workspace.Snapshot{Directory: path, Root: m.state.Root, Entries: rows, Sync: "Preview", CanBack: m.at > 0, CanForward: m.at+1 < len(m.history)}
}
func (m *DemoModel) Back() {
	if m.at > 0 {
		m.at--
		p := m.history[m.at]
		m.set(p, m.folders[p])
	}
}
func (m *DemoModel) Forward() {
	if m.at+1 < len(m.history) {
		m.at++
		p := m.history[m.at]
		m.set(p, m.folders[p])
	}
}
func (m *DemoModel) Refresh() { m.state.Error = "" }
func NewDemo() *Browser {
	home := filepath.FromSlash("/Users/alex")
	if runtime.GOOS == "windows" {
		home = `C:\Users\alex`
	}
	root := filepath.Join(home, "Projects", "terminal-finder")
	names := []string{"clients/", "core/", "docs/", "protocol/", "scripts/", "Cargo.lock", "Cargo.toml", "LICENSE", "README.md", "build.sh", "rust-toolchain.toml", ".gitignore"}
	m := &DemoModel{folders: map[string][]backend.Entry{}, history: []string{root}}
	for i, name := range names {
		dir := strings.HasSuffix(name, "/")
		name = strings.TrimSuffix(name, "/")
		n := uint64(1240 + i*831)
		date := fmt.Sprintf("2026-10-%02dT%02d:24:00Z", 17-i%9, 9+i%8)
		e := backend.Entry{Name: name, Path: filepath.Join(root, name), IsDirectory: dir, Size: &n, ModifiedAt: &date}
		m.folders[root] = append(m.folders[root], e)
		if dir {
			child := backend.Entry{Name: "src", Path: filepath.Join(e.Path, "src"), IsDirectory: true, ModifiedAt: &date}
			m.folders[e.Path] = []backend.Entry{child}
			m.folders[child.Path] = nil
		}
	}
	for _, p := range []string{home, filepath.Dir(root), filepath.Join(home, "Desktop"), filepath.Join(home, "Documents"), filepath.Join(home, "Downloads")} {
		m.folders[p] = []backend.Entry{{Name: filepath.Base(root), Path: root, IsDirectory: true}}
	}
	m.state.Root = root
	m.set(root, m.folders[root])
	return New(m, home, root)
}
