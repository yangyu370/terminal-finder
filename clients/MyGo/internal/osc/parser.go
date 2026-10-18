// Package osc observes working-directory reports without modifying PTY bytes.
package osc

import "strings"

const MaxSequence = 16 * 1024

type Parser struct {
	mode byte
	buf  []byte
}

func (p *Parser) Feed(data []byte) (reports []string) {
	finish := func() {
		if p.mode < 4 && strings.HasPrefix(string(p.buf), "7;") {
			reports = append(reports, string(p.buf[2:]))
		}
		p.mode, p.buf = 0, p.buf[:0]
	}
	for _, b := range data {
		if b == 0x18 || b == 0x1a {
			p.mode, p.buf = 0, p.buf[:0]
			continue
		}
		switch p.mode {
		case 0:
			if b == 0x1b {
				p.mode = 1
			}
		case 1:
			if b == ']' {
				p.mode = 2
				p.buf = p.buf[:0]
			} else if b != 0x1b {
				p.mode = 0
			}
		case 2, 4:
			if b == 7 {
				finish()
			} else if b == 0x1b {
				p.mode++
			} else if p.mode == 2 {
				if len(p.buf) >= MaxSequence {
					p.buf = p.buf[:0]
					p.mode = 4
				} else {
					p.buf = append(p.buf, b)
				}
			}
		case 3, 5:
			if b == '\\' {
				finish()
			} else if b == ']' {
				p.mode, p.buf = 2, p.buf[:0]
			} else if b == 7 {
				finish()
			} else if b != 0x1b {
				p.mode = 0
				p.buf = p.buf[:0]
			}
		}
	}
	return reports
}
