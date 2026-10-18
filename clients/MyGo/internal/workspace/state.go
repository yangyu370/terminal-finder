package workspace

// State is owned by the controller's serialized worker. A queued cd is not an
// acknowledgement that the shell moved; only a later validated report is.
type State struct {
	Directory   string
	Terminal    string
	Pending     bool
	AckSequence uint64
	Error       string
}

func (s *State) Opened(path string) {
	s.Directory, s.Pending, s.Error = path, true, ""
	s.AckSequence = ^uint64(0) // cannot confirm before the changeDirectory ack
}

func (s *State) Queued(sequence uint64) { s.AckSequence = sequence }
func (s *State) Failed(message string)  { s.Error = message }

// Report returns true when the browser should follow a shell-initiated cd.
func (s *State) Report(path string, sequence uint64) bool {
	s.Terminal = path
	if s.Pending {
		if path == s.Directory && sequence > s.AckSequence {
			s.Pending = false
			s.Error = ""
		}
		return false
	}
	return path != s.Directory
}

func (s State) Status() string {
	if s.Error != "" {
		return "Sync blocked"
	}
	if s.Pending {
		return "Waiting for terminal"
	}
	if s.Terminal == "" {
		return "Starting terminal"
	}
	if s.Terminal != s.Directory {
		return "Syncing directory"
	}
	return "Synced"
}
