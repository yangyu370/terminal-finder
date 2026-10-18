package launch

import (
	"path/filepath"
	"testing"
)

func TestDefaultCorePathUsesPlatformBundleLayout(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct{ platform, want string }{
		{"windows", filepath.Join(dir, "core.exe")},
		{"darwin", filepath.Join(dir, "..", "Resources", "terminal-finder-core")},
	} {
		if got := DefaultCorePath(filepath.Join(dir, "client"), tc.platform); got != tc.want {
			t.Fatalf("%s: %s", tc.platform, got)
		}
	}
}
