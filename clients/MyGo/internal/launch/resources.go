package launch

import "path/filepath"

func DefaultCorePath(executable, platform string) string {
	if platform == "windows" {
		return filepath.Join(filepath.Dir(executable), "core.exe")
	}
	return filepath.Join(filepath.Dir(executable), "..", "Resources", "terminal-finder-core")
}
