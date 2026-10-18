package backend

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"terminal-finder-mygo/internal/osc"
)

type Envelope struct {
	Type      string          `json:"type"`
	SessionID string          `json:"sessionId,omitempty"`
	ID        string          `json:"id,omitempty"`
	Data      json.RawMessage `json:"data"`
	Sequence  uint64          `json:"-"`
}
type CwdReport struct {
	URL      string
	Sequence uint64
}
type WorkingDirectory struct {
	ReportedDirectory string  `json:"reportedDirectory"`
	Openable          bool    `json:"openable"`
	MatchesCurrent    bool    `json:"matchesCurrent"`
	Reason            *string `json:"reason"`
}

type Terminal struct {
	ws       *websocket.Conn
	writeMu  sync.Mutex
	mu       sync.Mutex
	cond     *sync.Cond
	buffer   bytes.Buffer
	pending  map[string]chan Envelope
	session  string
	closed   bool
	err      error
	done     chan struct{}
	finished chan struct{}
	next     atomic.Uint64
	onCwd    func(CwdReport)
}

func (c *Client) Connect(ctx context.Context, onCwd func(CwdReport)) (*Terminal, error) {
	d := websocket.Dialer{HandshakeTimeout: 5 * time.Second, Proxy: nil}
	ws, r, err := d.DialContext(ctx, "ws"+strings.TrimPrefix(c.base, "http")+"/terminal", nil)
	if r != nil && r.Body != nil {
		r.Body.Close()
	}
	if err != nil {
		return nil, err
	}
	ws.SetReadLimit(8 << 20)
	t := &Terminal{ws: ws, pending: make(map[string]chan Envelope), done: make(chan struct{}), finished: make(chan struct{}), onCwd: onCwd}
	t.cond = sync.NewCond(&t.mu)
	go t.readLoop()
	return t, nil
}

func (t *Terminal) Start(ctx context.Context) error {
	r, err := t.call(ctx, "terminal.createWorkspace", map[string]int{"cols": 100, "rows": 28})
	if err != nil {
		return err
	}
	if r.Type != "terminal.created" || r.SessionID == "" {
		return fmt.Errorf("invalid create acknowledgement")
	}
	return nil
}
func (t *Terminal) Validate(ctx context.Context, url string) (WorkingDirectory, error) {
	r, err := t.call(ctx, "terminal.updateWorkingDirectory", map[string]string{"directoryUrl": url})
	var d WorkingDirectory
	if err == nil {
		err = json.Unmarshal(r.Data, &d)
	}
	return d, err
}
func (t *Terminal) ChangeDirectory(ctx context.Context, path string) (uint64, error) {
	r, err := t.call(ctx, "terminal.changeDirectory", map[string]string{"targetDirectory": path})
	if err != nil {
		return 0, err
	}
	var d struct {
		Queued bool   `json:"queued"`
		Reason string `json:"reason"`
	}
	if err = json.Unmarshal(r.Data, &d); err != nil {
		return 0, err
	}
	if !d.Queued {
		return 0, fmt.Errorf("directory change refused: %s", d.Reason)
	}
	return r.Sequence, nil
}

func (t *Terminal) call(ctx context.Context, kind string, data any) (Envelope, error) {
	id := fmt.Sprint(t.next.Add(1))
	reply := make(chan Envelope, 1)
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return Envelope{}, io.ErrClosedPipe
	}
	t.pending[id] = reply
	t.mu.Unlock()
	defer func() { t.mu.Lock(); delete(t.pending, id); t.mu.Unlock() }()
	if err := t.send(kind, id, data); err != nil {
		return Envelope{}, err
	}
	select {
	case r := <-reply:
		if r.Type == "terminal.error" {
			var d struct{ Code, Message string }
			json.Unmarshal(r.Data, &d)
			return r, fmt.Errorf("%s: %s", d.Code, d.Message)
		}
		return r, nil
	case <-ctx.Done():
		return Envelope{}, ctx.Err()
	case <-t.done:
		// A successful reply may arrive immediately before shell exit.
		select {
		case r := <-reply:
			return r, nil
		default:
		}
		return Envelope{}, t.Err()
	}
}
func (t *Terminal) send(kind, id string, data any) error {
	body, err := json.Marshal(data)
	if err != nil {
		return err
	}
	t.mu.Lock()
	session, closed := t.session, t.closed
	t.mu.Unlock()
	if closed {
		return io.ErrClosedPipe
	}
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	t.ws.SetWriteDeadline(time.Now().Add(3 * time.Second))
	return t.ws.WriteJSON(Envelope{Type: kind, ID: id, SessionID: session, Data: body})
}
func (t *Terminal) readLoop() {
	defer close(t.finished)
	defer t.ws.Close()
	var parser osc.Parser
	var sequence uint64
	for {
		var r Envelope
		if err := t.ws.ReadJSON(&r); err != nil {
			t.finish(fmt.Errorf("terminal disconnected: %w", err))
			return
		}
		sequence++
		r.Sequence = sequence
		t.mu.Lock()
		reply := t.pending[r.ID]
		if reply != nil && r.Type == "terminal.created" {
			t.session = r.SessionID
		}
		session := t.session
		t.mu.Unlock()
		if reply != nil {
			select {
			case reply <- r:
			default:
			}
			continue
		}
		if r.SessionID != session || session == "" {
			continue
		}
		switch r.Type {
		case "terminal.output":
			var data struct {
				Bytes string `json:"bytes"`
			}
			if err := json.Unmarshal(r.Data, &data); err != nil {
				t.finish(err)
				return
			}
			b, err := base64.StdEncoding.DecodeString(data.Bytes)
			if err != nil {
				t.finish(err)
				return
			}
			for _, url := range parser.Feed(b) {
				if t.onCwd != nil {
					t.onCwd(CwdReport{url, sequence})
				}
			}
			t.mu.Lock()
			if t.buffer.Len()+len(b) > 8<<20 {
				t.mu.Unlock()
				t.finish(errors.New("terminal output buffer exceeded 8 MiB"))
				return
			}
			t.buffer.Write(b)
			t.cond.Broadcast()
			t.mu.Unlock()
		case "terminal.exit":
			t.finish(io.EOF)
			return
		case "terminal.error":
			var d struct{ Message string }
			json.Unmarshal(r.Data, &d)
			t.finish(errors.New(d.Message))
			return
		}
	}
}
func (t *Terminal) finish(err error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.closed {
		t.closed = true
		t.err = err
		close(t.done)
		t.cond.Broadcast()
	}
}
func (t *Terminal) Done() <-chan struct{} { return t.done }
func (t *Terminal) Err() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.err == nil {
		return io.ErrClosedPipe
	}
	return t.err
}
func (t *Terminal) Read(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for t.buffer.Len() == 0 && !t.closed {
		t.cond.Wait()
	}
	if t.buffer.Len() > 0 {
		return t.buffer.Read(p)
	}
	if t.err != nil {
		return 0, t.err
	}
	return 0, io.EOF
}
func (t *Terminal) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	err := t.send("terminal.input", "", map[string]string{"bytes": base64.StdEncoding.EncodeToString(p)})
	if err != nil {
		return 0, err
	}
	return len(p), nil
}
func (t *Terminal) Resize(cols, rows int) error {
	if cols < 1 || rows < 1 || cols > 65535 || rows > 65535 {
		return errors.New("invalid terminal size")
	}
	return t.send("terminal.resize", "", map[string]int{"cols": cols, "rows": rows})
}
func (t *Terminal) Close() error {
	// Socket closure also makes Rust close all sessions owned by this socket.
	t.send("terminal.close", "", map[string]any{})
	t.finish(io.EOF)
	t.ws.Close()
	<-t.finished
	return nil
}
