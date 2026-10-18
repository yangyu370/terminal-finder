package workspace

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"terminal-finder-mygo/internal/backend"
)

type fakeAPI struct {
	mu    sync.Mutex
	paths []string
	block chan struct{}
}

func (f *fakeAPI) Open(ctx context.Context, path string) (backend.OpenResult, error) {
	if path == testPath("slow") && f.block != nil {
		select {
		case <-f.block:
		case <-ctx.Done():
			return backend.OpenResult{}, ctx.Err()
		}
	}
	f.mu.Lock()
	f.paths = append(f.paths, path)
	f.mu.Unlock()
	if path == testPath("missing") {
		return backend.OpenResult{}, errors.New("missing directory")
	}
	return initial(path), nil
}

type fakeSession struct {
	mu      sync.Mutex
	changes []string
	done    chan struct{}
}

func (f *fakeSession) ChangeDirectory(_ context.Context, path string) (uint64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.changes = append(f.changes, path)
	return 10, nil
}
func (f *fakeSession) Validate(_ context.Context, url string) (backend.WorkingDirectory, error) {
	return backend.WorkingDirectory{ReportedDirectory: url, Openable: true}, nil
}
func (f *fakeSession) Done() <-chan struct{} { return f.done }
func (f *fakeSession) Err() error            { return errors.New("disconnected") }
func initial(path string) backend.OpenResult {
	return backend.OpenResult{State: backend.Workspace{CurrentDirectory: path, WorkspaceRoot: "/", Scheme: "local"}, Listing: backend.Listing{Path: path, Entries: []backend.Entry{{Name: "folder", Path: filepath.Join(path, "folder"), IsDirectory: true}}}}
}
func waitFor(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if f() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition timed out")
}

func TestControllerBidirectionalAndFailureHistory(t *testing.T) {
	a := &fakeAPI{}
	s := &fakeSession{done: make(chan struct{})}
	c := NewController(a, initial(testPath("old")))
	c.Start(s)
	defer c.Close()
	c.Navigate(testPath("new"))
	waitFor(t, func() bool { return c.Snapshot().Directory == testPath("new") })
	c.Observe(backend.CwdReport{URL: testPath("old"), Sequence: 20})
	c.Observe(backend.CwdReport{URL: testPath("new"), Sequence: 21})
	waitFor(t, func() bool { return c.Snapshot().Sync == "Synced" })
	c.Observe(backend.CwdReport{URL: testPath("shell"), Sequence: 22})
	waitFor(t, func() bool { return c.Snapshot().Directory == testPath("shell") })
	s.mu.Lock()
	if len(s.changes) != 1 || s.changes[0] != testPath("new") {
		t.Fatal(s.changes)
	}
	s.mu.Unlock()
	c.Navigate(testPath("missing"))
	waitFor(t, func() bool { return c.Snapshot().Error != "" })
	if got := c.Snapshot(); got.Directory != testPath("shell") || len(got.Entries) != 1 || !got.CanBack {
		t.Fatal(got)
	}
	c.Back()
	waitFor(t, func() bool { return c.Snapshot().Directory == testPath("new") })
}

func TestSlowResponseCannotOverwriteLatestNavigation(t *testing.T) {
	a := &fakeAPI{block: make(chan struct{})}
	s := &fakeSession{done: make(chan struct{})}
	c := NewController(a, initial(testPath("old")))
	c.Start(s)
	defer c.Close()
	c.Navigate(testPath("slow"))
	time.Sleep(20 * time.Millisecond)
	c.Navigate(testPath("latest"))
	close(a.block)
	waitFor(t, func() bool { return c.Snapshot().Directory == testPath("latest") })
	c.Observe(backend.CwdReport{URL: testPath("slow"), Sequence: 50})
	c.Observe(backend.CwdReport{URL: testPath("latest"), Sequence: 51})
	waitFor(t, func() bool { return c.Snapshot().Sync == "Synced" })
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.changes {
		if p == testPath("slow") {
			t.Fatal("stale response changed terminal")
		}
	}
}

func TestDisconnectStopsClaimingSynced(t *testing.T) {
	s := &fakeSession{done: make(chan struct{})}
	c := NewController(&fakeAPI{}, initial(testPath("old")))
	c.Start(s)
	defer c.Close()
	c.Observe(backend.CwdReport{URL: testPath("old"), Sequence: 1})
	waitFor(t, func() bool { return c.Snapshot().Sync == "Synced" })
	close(s.done)
	waitFor(t, func() bool { return c.Snapshot().Disconnected })
	if c.Snapshot().Sync == "Synced" {
		t.Fatal("disconnected but synced")
	}
}

func TestUnconfirmedDirectoryChangeIsRetried(t *testing.T) {
	s := &fakeSession{done: make(chan struct{})}
	c := NewController(&fakeAPI{}, initial(testPath("old")))
	c.Start(s)
	defer c.Close()
	c.Navigate(testPath("new"))
	waitFor(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.changes) >= 2 })
	c.Observe(backend.CwdReport{URL: testPath("new"), Sequence: 100})
	waitFor(t, func() bool { return c.Snapshot().Sync == "Synced" })
}

func testPath(name string) string {
	p, err := filepath.Abs(filepath.Join("test-workspace", name))
	if err != nil {
		panic(err)
	}
	return p
}

type canonicalSession struct{ fakeSession }

func (s *canonicalSession) Validate(_ context.Context, _ string) (backend.WorkingDirectory, error) {
	return backend.WorkingDirectory{ReportedDirectory: "C:\\same", Openable: true, MatchesCurrent: true}, nil
}
func TestCoreCanonicalMatchConfirmsDifferentPathSpelling(t *testing.T) {
	a := &fakeAPI{}
	s := &canonicalSession{fakeSession: fakeSession{done: make(chan struct{})}}
	c := NewController(a, initial(testPath("old")))
	c.Start(s)
	defer c.Close()
	c.Navigate(testPath("new"))
	waitFor(t, func() bool { s.mu.Lock(); defer s.mu.Unlock(); return len(s.changes) > 0 })
	c.Observe(backend.CwdReport{URL: "file:///C:/same", Sequence: 100})
	waitFor(t, func() bool { return c.Snapshot().Sync == "Synced" })
	if c.Snapshot().Directory != testPath("new") {
		t.Fatal(c.Snapshot())
	}
}
