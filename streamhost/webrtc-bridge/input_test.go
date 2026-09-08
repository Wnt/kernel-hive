package main

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestInputChannelTag(t *testing.T) {
	cases := map[string]struct {
		want byte
		ok   bool
	}{
		"input-rel": {inputChannelRel, true},
		"input":     {inputChannelReliable, true},
		"video":     {0, false},
		"":          {0, false},
	}
	for label, exp := range cases {
		got, ok := inputChannelTag(label)
		if got != exp.want || ok != exp.ok {
			t.Fatalf("label %q: got (%d,%v) want (%d,%v)", label, got, ok, exp.want, exp.ok)
		}
	}
}

func TestEncodeInputFrame(t *testing.T) {
	payload := []byte{0x02, 0x00, 0x01} // a bare button record
	frame := encodeInputFrame(inputChannelReliable, payload)
	if n := binary.LittleEndian.Uint32(frame[0:4]); n != uint32(1+len(payload)) {
		t.Fatalf("len = %d, want %d", n, 1+len(payload))
	}
	if frame[4] != inputChannelReliable {
		t.Fatalf("channel = %d, want %d", frame[4], inputChannelReliable)
	}
	if string(frame[5:]) != string(payload) {
		t.Fatalf("payload mismatch")
	}
}

// forwardInput must dial the per-tile socket, send the OSGWI1 handshake, then
// frame the ticket (reliable, first) and a following move (rel) in order.
func TestForwardInputDialsHandshakeAndFrames(t *testing.T) {
	dir := t.TempDir()
	p := &platform{inputDir: dir}
	h := &hub{tile: "win311", platform: p}
	s := &peerSession{hub: h}

	ln, err := net.Listen("unix", p.inputSocketPath("win311"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	got := make(chan []byte, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		r := bufio.NewReader(conn)
		magic := make([]byte, len(inputFeedMagic))
		if _, err := io.ReadFull(r, magic); err != nil || string(magic) != inputFeedMagic {
			t.Errorf("bad handshake %q err=%v", magic, err)
			return
		}
		var buf []byte
		hdr := make([]byte, 4)
		for i := 0; i < 2; i++ {
			if _, err := io.ReadFull(r, hdr); err != nil {
				return
			}
			n := binary.LittleEndian.Uint32(hdr)
			rec := make([]byte, n)
			if _, err := io.ReadFull(r, rec); err != nil {
				return
			}
			buf = append(buf, rec...) // [channel][payload...]
		}
		got <- buf
	}()

	s.forwardInput(inputChannelReliable, []byte("/wt/1.n.sig")) // ticket first
	s.forwardInput(inputChannelRel, []byte{0x04, 0x01, 0x00, 0x02, 0x00})
	s.closeInput()

	select {
	case buf := <-got:
		if buf[0] != inputChannelReliable {
			t.Fatalf("first frame channel = %d, want reliable", buf[0])
		}
		if string(buf[1:1+len("/wt/1.n.sig")]) != "/wt/1.n.sig" {
			t.Fatalf("first frame is not the ticket: %q", buf[1:])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for forwarded frames")
	}
}

func TestForwardInputMissingSocketIsInert(t *testing.T) {
	p := &platform{inputDir: filepath.Join(t.TempDir(), "nope")}
	h := &hub{tile: "win311", platform: p}
	s := &peerSession{hub: h}
	s.forwardInput(inputChannelRel, []byte{0x04, 0, 0, 0, 0}) // must not panic
	if !s.inputDown {
		t.Fatal("expected inputDown latched after a missing socket")
	}
	_ = os.Remove // keep os imported for symmetry with the listen test
}
