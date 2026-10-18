// Package backend adapts the existing optional Rust server; it owns no
// filesystem facts and never launches its own terminal shell.
package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Entry struct {
	Name        string  `json:"name"`
	Path        string  `json:"path"`
	IsDirectory bool    `json:"isDirectory"`
	Kind        string  `json:"kind"`
	Size        *uint64 `json:"size"`
	ModifiedAt  *string `json:"modifiedAt"`
}
type Workspace struct {
	CurrentDirectory string `json:"currentDirectory"`
	WorkspaceRoot    string `json:"workspaceRoot"`
	Scheme           string `json:"scheme"`
}
type Listing struct {
	Path    string  `json:"path"`
	Entries []Entry `json:"entries"`
}
type OpenResult struct {
	State   Workspace `json:"state"`
	Listing Listing   `json:"listing"`
}
type Client struct {
	base string
	http *http.Client
}

func New(endpoint string) (*Client, error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}
	host := u.Hostname()
	ip := net.ParseIP(host)
	if u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || (host != "localhost" && (ip == nil || !ip.IsLoopback())) {
		return nil, fmt.Errorf("backend must be a plain HTTP loopback origin")
	}
	return &Client{base: strings.TrimSuffix(endpoint, "/"), http: &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func (c *Client) Health(ctx context.Context) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", c.base+"/health", nil)
	r, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	var data struct {
		Service string `json:"service"`
	}
	if r.StatusCode != 200 {
		return fmt.Errorf("health: HTTP %d", r.StatusCode)
	}
	if err = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&data); err != nil {
		return err
	}
	if data.Service != "terminal-finder-core" {
		return fmt.Errorf("port is occupied by a different service")
	}
	return nil
}

func (c *Client) Open(ctx context.Context, path string) (OpenResult, error) {
	var result OpenResult
	err := c.rpc(ctx, "workspace.openDirectory", map[string]any{"path": path}, &result)
	if err == nil && (result.State.CurrentDirectory == "" || result.State.Scheme != "local") {
		err = fmt.Errorf("MVP requires a local workspace")
	}
	return result, err
}
func (c *Client) rpc(ctx context.Context, method string, params any, result any) error {
	body, err := json.Marshal(map[string]any{"method": method, "params": params})
	if err != nil {
		return err
	}
	req, _ := http.NewRequestWithContext(ctx, "POST", c.base+"/rpc", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	r, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer r.Body.Close()
	var envelope struct {
		OK     bool                           `json:"ok"`
		Result json.RawMessage                `json:"result"`
		Error  struct{ Code, Message string } `json:"error"`
	}
	if err = json.NewDecoder(io.LimitReader(r.Body, 32<<20)).Decode(&envelope); err != nil {
		return fmt.Errorf("RPC response: %w", err)
	}
	if r.StatusCode != 200 || !envelope.OK {
		return fmt.Errorf("%s: %s (HTTP %d)", envelope.Error.Code, envelope.Error.Message, r.StatusCode)
	}
	return json.Unmarshal(envelope.Result, result)
}
