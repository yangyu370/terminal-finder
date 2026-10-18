package workspace

import "testing"

func TestNavigationWaitsForConfirmationAndIgnoresStaleReports(t *testing.T) {
	s := State{Directory: "/old"}
	s.Opened("/new")
	s.Queued(40)
	if s.Report("/old", 45) || !s.Pending {
		t.Fatal("old cwd reversed navigation")
	}
	if s.Report("/new", 39) || !s.Pending {
		t.Fatal("pre-ack cwd confirmed navigation")
	}
	if s.Report("/new", 41) || s.Pending || s.Status() != "Synced" {
		t.Fatalf("not confirmed: %+v", s)
	}
	if !s.Report("/shell", 50) {
		t.Fatal("shell cd must request browser navigation")
	}
}

func TestRapidNavigationKeepsNewestTarget(t *testing.T) {
	s := State{Directory: "/old"}
	s.Opened("/a")
	s.Queued(10)
	s.Opened("/b")
	s.Queued(20)
	s.Report("/a", 21)
	if s.Directory != "/b" || !s.Pending {
		t.Fatalf("stale target: %+v", s)
	}
	s.Report("/b", 22)
	if s.Pending {
		t.Fatal("latest target not confirmed")
	}
}

func TestFailurePreservesDirectoryAndDoesNotClaimSync(t *testing.T) {
	s := State{Directory: "/old", Terminal: "/old"}
	s.Failed("unreadable")
	if s.Directory != "/old" || s.Status() == "Synced" {
		t.Fatalf("%+v", s)
	}
	s.Error = ""
	s.Opened("/new")
	s.Failed("terminal disconnected")
	if s.Status() == "Synced" || s.Directory != "/new" {
		t.Fatalf("%+v", s)
	}
}
