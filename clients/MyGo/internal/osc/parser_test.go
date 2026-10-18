package osc

import (
	"strings"
	"testing"
)

func TestEveryChunkBoundary(t *testing.T) {
	for _, end := range []string{"\a", "\x1b\\"} {
		input := "\xffhello\x1b]7;file://localhost/tmp/%E4%B8%AD%20a" + end + "tail"
		for cut := 0; cut <= len(input); cut++ {
			var p Parser
			got := append(p.Feed([]byte(input[:cut])), p.Feed([]byte(input[cut:]))...)
			if len(got) != 1 || got[0] != "file://localhost/tmp/%E4%B8%AD%20a" {
				t.Fatalf("cut=%d got=%q", cut, got)
			}
		}
	}
}

func TestBoundedAndRecovery(t *testing.T) {
	var p Parser
	p.Feed([]byte("\x1b]7;" + strings.Repeat("x", MaxSequence*2)))
	if len(p.buf) > MaxSequence {
		t.Fatal("unbounded buffer")
	}
	got := p.Feed([]byte("\a\x1b]0;title\a\x1b]7;file:///tmp\a\x1b]7;file:///other\x1b\\"))
	if len(got) != 2 || got[0] != "file:///tmp" || got[1] != "file:///other" {
		t.Fatal(got)
	}
}

func TestBytewiseAndCancel(t *testing.T) {
	var p Parser
	var got []string
	for _, b := range []byte("\x1b]7;bad\x18\x1b]7;file:///tmp\x1b\\") {
		got = append(got, p.Feed([]byte{b})...)
	}
	if len(got) != 1 || got[0] != "file:///tmp" {
		t.Fatal(got)
	}
}
