package backend

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRPCContractAndFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string
			Params map[string]any
		}
		json.NewDecoder(r.Body).Decode(&req)
		if r.URL.Path != "/rpc" || req.Method != "workspace.openDirectory" || req.Params["path"] != "/tmp" {
			t.Errorf("bad request: %+v", req)
		}
		io.WriteString(w, `{"ok":true,"result":{"state":{"currentDirectory":"/tmp","workspaceRoot":"/tmp","scheme":"local"},"listing":{"path":"/tmp","entries":[{"name":"x","path":"/tmp/x","isDirectory":true}]}}}`)
	}))
	defer srv.Close()
	c, err := New(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	r, err := c.Open(context.Background(), "/tmp")
	if err != nil || r.State.CurrentDirectory != "/tmp" || len(r.Listing.Entries) != 1 || !r.Listing.Entries[0].IsDirectory {
		t.Fatalf("%+v %v", r, err)
	}
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		io.WriteString(w, `{"ok":false,"error":{"code":"invalid_path","message":"missing directory"}}`)
	})
	if _, err := c.Open(context.Background(), "/tmp"); err == nil || !strings.Contains(err.Error(), "missing directory") {
		t.Fatal(err)
	}
}

func TestRejectNonLoopback(t *testing.T) {
	for _, raw := range []string{"http://example.com:3587", "https://127.0.0.1:3587", "http://user@localhost:3587", "http://127.0.0.1:3587/rpc"} {
		if _, err := New(raw); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
}

func TestTerminalRawBytesCorrelatedRepliesAndDisconnect(t *testing.T) {
	raw := []byte{0xff, 0, 27, '[', 'm'}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var req Envelope
		if ws.ReadJSON(&req) != nil {
			return
		}
		ws.WriteJSON(Envelope{Type: "terminal.created", ID: "wrong", SessionID: "wrong", Data: json.RawMessage(`{}`)})
		ws.WriteJSON(Envelope{Type: "terminal.created", ID: req.ID, SessionID: "session", Data: json.RawMessage(`{}`)})
		data, _ := json.Marshal(map[string]string{"bytes": base64.StdEncoding.EncodeToString(raw)})
		ws.WriteJSON(Envelope{Type: "terminal.output", SessionID: "session", Data: data})
		ws.WriteJSON(Envelope{Type: "terminal.exit", SessionID: "session", Data: json.RawMessage(`{"code":0}`)})
	}))
	defer srv.Close()
	c, _ := New(srv.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	term, err := c.Connect(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer term.Close()
	if err = term.Start(ctx); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(term)
	if err != nil || string(got) != string(raw) {
		t.Fatalf("%x %v", got, err)
	}
}

func TestTerminalRequestTimeout(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, e := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer ws.Close()
		for {
			if _, _, e = ws.ReadMessage(); e != nil {
				return
			}
		}
	}))
	defer srv.Close()
	c, _ := New(srv.URL)
	term, e := c.Connect(context.Background(), nil)
	if e != nil {
		t.Fatal(e)
	}
	defer term.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if e = term.Start(ctx); e == nil {
		t.Fatal("missing timeout")
	}
}
