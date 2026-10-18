package workspace

import (
	"context"
	"fmt"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"terminal-finder-mygo/internal/backend"
)

type API interface {
	Open(context.Context, string) (backend.OpenResult, error)
}
type Session interface {
	ChangeDirectory(context.Context, string) (uint64, error)
	Validate(context.Context, string) (backend.WorkingDirectory, error)
	Done() <-chan struct{}
	Err() error
}
type Snapshot struct {
	Directory, Root, TerminalDirectory, Sync, Error string
	Entries                                         []backend.Entry
	Loading, CanBack, CanForward, Disconnected      bool
}
type navigation struct {
	path     string
	step     int
	revision uint64
	refresh  bool
}
type observation struct {
	report   backend.CwdReport
	revision uint64
}

type Controller struct {
	api      API
	term     Session
	ctx      context.Context
	cancel   context.CancelFunc
	done     chan struct{}
	nav      chan struct{}
	reports  chan observation
	revision atomic.Uint64
	mu       sync.Mutex
	queued   *navigation
	snapshot Snapshot
	notify   func()
	started  bool
	// Everything below is owned by the worker.
	state    State
	history  []string
	position int
}

func NewController(api API, initial backend.OpenResult) *Controller {
	ctx, cancel := context.WithCancel(context.Background())
	c := &Controller{api: api, ctx: ctx, cancel: cancel, done: make(chan struct{}), nav: make(chan struct{}, 1), reports: make(chan observation, 64), history: []string{initial.State.CurrentDirectory}}
	c.state.Directory = initial.State.CurrentDirectory
	c.snapshot = Snapshot{Directory: initial.State.CurrentDirectory, Root: initial.State.WorkspaceRoot, Entries: initial.Listing.Entries, Sync: c.state.Status()}
	return c
}
func (c *Controller) SetNotify(fn func()) { c.mu.Lock(); c.notify = fn; c.mu.Unlock() }
func (c *Controller) Snapshot() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	s := c.snapshot
	s.Entries = append([]backend.Entry(nil), s.Entries...)
	return s
}
func (c *Controller) Start(term Session) {
	c.mu.Lock()
	if c.started {
		c.mu.Unlock()
		panic("controller already started")
	}
	c.started = true
	c.term = term
	c.mu.Unlock()
	go c.run()
}
func (c *Controller) Close() {
	c.cancel()
	c.mu.Lock()
	started := c.started
	c.mu.Unlock()
	if started {
		<-c.done
	}
}
func (c *Controller) Navigate(path string) { c.enqueue(navigation{path: path}) }
func (c *Controller) Back()                { c.enqueue(navigation{step: -1}) }
func (c *Controller) Forward()             { c.enqueue(navigation{step: 1}) }
func (c *Controller) Refresh()             { c.enqueue(navigation{refresh: true}) }
func (c *Controller) enqueue(n navigation) {
	c.mu.Lock()
	if c.ctx.Err() != nil {
		c.mu.Unlock()
		return
	}
	n.revision = c.revision.Add(1)
	c.queued = &n
	c.snapshot.Loading = true
	fn := c.notify
	c.mu.Unlock()
	select {
	case c.nav <- struct{}{}:
	default:
	}
	if fn != nil {
		fn()
	}
}
func (c *Controller) Observe(r backend.CwdReport) {
	o := observation{r, c.revision.Load()}
	// A blocked network operation must not stall the PTY output reader.
	select {
	case c.reports <- o:
	default:
		select {
		case <-c.reports:
		default:
		}
		select {
		case c.reports <- o:
		default:
		}
	}
}
func (c *Controller) publish(result *backend.OpenResult) {
	c.mu.Lock()
	if result != nil {
		c.snapshot.Directory = result.State.CurrentDirectory
		c.snapshot.Root = result.State.WorkspaceRoot
		c.snapshot.Entries = result.Listing.Entries
	}
	c.snapshot.TerminalDirectory = c.state.Terminal
	c.snapshot.Sync = c.state.Status()
	c.snapshot.Error = c.state.Error
	c.snapshot.CanBack = c.position > 0
	c.snapshot.CanForward = c.position+1 < len(c.history)
	if c.queued == nil {
		c.snapshot.Loading = false
	}
	fn := c.notify
	c.mu.Unlock()
	if fn != nil {
		fn()
	}
}
func (c *Controller) run() {
	defer close(c.done)
	// The first OSC 7 precedes zsh's line-init FIFO registration. A queued
	// request survives, but its nonblocking wake can be missed at startup.
	// Requeue the latest target through the same controlled API; never type
	// into stdin, including while a foreground program owns the terminal.
	retry := time.NewTicker(time.Second)
	defer retry.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-c.term.Done():
			c.state.Failed(c.term.Err().Error())
			c.mu.Lock()
			c.snapshot.Disconnected = true
			c.mu.Unlock()
			c.publish(nil)
			return
		case <-c.nav:
			c.mu.Lock()
			n := c.queued
			c.queued = nil
			c.mu.Unlock()
			if n != nil {
				c.navigate(*n)
			}
		case o := <-c.reports:
			c.observe(o)
		case <-retry.C:
			if c.state.Pending && c.state.Error == "" {
				revision := c.revision.Load()
				ctx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
				ack, err := c.term.ChangeDirectory(ctx, c.state.Directory)
				cancel()
				if revision == c.revision.Load() {
					if err != nil {
						c.state.Failed(err.Error())
					} else {
						c.state.Queued(ack)
					}
					c.publish(nil)
				}
			}
		}
	}
}
func (c *Controller) navigate(n navigation) {
	if n.revision != c.revision.Load() {
		return
	}
	path := n.path
	position := c.position
	if n.step != 0 {
		position += n.step
		if position < 0 || position >= len(c.history) {
			c.publish(nil)
			return
		}
		path = c.history[position]
	}
	if n.refresh {
		path = c.state.Directory
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(c.state.Directory, path)
	}
	ctx, cancel := context.WithTimeout(c.ctx, 10*time.Second)
	defer cancel()
	result, err := c.api.Open(ctx, path)
	if n.revision != c.revision.Load() {
		return
	}
	if err != nil {
		c.state.Failed(err.Error())
		c.publish(nil)
		return
	}
	if n.step != 0 {
		c.position = position
	} else {
		c.remember(result.State.CurrentDirectory)
	}
	if n.refresh && result.State.CurrentDirectory == c.state.Directory {
		c.state.Error = ""
		c.publish(&result)
		return
	}
	c.state.Opened(result.State.CurrentDirectory)
	c.publish(&result)
	ack, err := c.term.ChangeDirectory(ctx, c.state.Directory)
	if n.revision != c.revision.Load() {
		return
	}
	if err != nil {
		c.state.Failed(err.Error())
	} else {
		c.state.Queued(ack)
	}
	c.publish(nil)
}
func (c *Controller) observe(o observation) {
	if o.revision != c.revision.Load() {
		return
	}
	ctx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
	defer cancel()
	r, err := c.term.Validate(ctx, o.report.URL)
	if o.revision != c.revision.Load() {
		return
	}
	if err != nil {
		c.state.Failed(err.Error())
		c.publish(nil)
		return
	}
	if !r.Openable || r.ReportedDirectory == "" {
		reason := "not openable"
		if r.Reason != nil {
			reason = *r.Reason
		}
		c.state.Failed(fmt.Sprint("Cannot follow terminal directory: ", reason))
		c.publish(nil)
		return
	}
	// Core has canonicalized both paths. Windows drive casing/verbatim
	// prefixes can differ even when they name the same directory.
	reported := r.ReportedDirectory
	if r.MatchesCurrent {
		reported = c.state.Directory
	}
	if !c.state.Report(reported, o.report.Sequence) {
		c.publish(nil)
		return
	}
	result, err := c.api.Open(ctx, r.ReportedDirectory)
	if o.revision != c.revision.Load() {
		return
	}
	if err != nil {
		c.state.Failed(err.Error())
		c.publish(nil)
		return
	}
	c.state.Directory = result.State.CurrentDirectory
	c.state.Terminal = result.State.CurrentDirectory
	c.state.Error = ""
	c.remember(c.state.Directory)
	c.publish(&result)
}
func (c *Controller) remember(path string) {
	if c.history[c.position] == path {
		return
	}
	c.history = append(c.history[:c.position+1], path)
	c.position = len(c.history) - 1
	if len(c.history) > 128 {
		c.history = append([]string(nil), c.history[len(c.history)-128:]...)
		c.position = len(c.history) - 1
	}
}
