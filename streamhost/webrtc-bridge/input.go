// Input plane: forward each peer's WebRTC DataChannel messages to the daemon's
// per-tile Unix input socket. The bridge is a dumb pipe here — it neither reads
// nor verifies the ticket that leads the reliable channel; the daemon does that
// (streamhost/src/webrtc_input.rs). One daemon connection per peer, dialed on
// the first message and closed with the peer, so the daemon can scope a session
// (and its ticket) to exactly one WebRTC peer.
package main

import (
	"encoding/binary"
	"log"
	"net"
	"path/filepath"
)

// The two DataChannel labels the SPA opens, and the channel tag each maps to on
// the bridge→daemon wire: 0 = unreliable (moves + re-home hint), 1 = reliable
// (buttons/keys/wheel, ticket-first). Kept in lockstep with the labels in
// spa/src/three/webRtcFallbackClient.ts.
const (
	inputChannelRel      = 0
	inputChannelReliable = 1
	inputFeedMagic       = "OSGWI1"
	maxInputRecordBytes  = 4 << 10
)

func inputChannelTag(label string) (byte, bool) {
	switch label {
	case "input-rel":
		return inputChannelRel, true
	case "input":
		return inputChannelReliable, true
	default:
		return 0, false
	}
}

// encodeInputFrame frames one channel message for the daemon input socket:
//
//	[len u32 LE][channel u8][payload...]   where len = 1 + len(payload)
//
// A DataChannel message is already a boundary, so exactly one record (or the
// leading ticket) rides one frame; the record stays self-describing (its first
// byte is the input type the daemon dispatches on).
func encodeInputFrame(channel byte, payload []byte) []byte {
	frame := make([]byte, 5+len(payload))
	binary.LittleEndian.PutUint32(frame[0:4], uint32(1+len(payload)))
	frame[4] = channel
	copy(frame[5:], payload)
	return frame
}

func (p *platform) inputSocketPath(tile string) string {
	return filepath.Join(p.inputDir, "input-"+tile+".sock")
}

// forwardInput dials the daemon input socket for this peer's tile on first use
// and writes one framed record. A missing socket (a station whose daemon has no
// input listener — env-gated, or a pre-input daemon) latches inputDown so video
// keeps flowing and the failure is logged once, not per message.
func (s *peerSession) forwardInput(channel byte, data []byte) {
	if len(data) > maxInputRecordBytes {
		return
	}
	s.inputMu.Lock()
	defer s.inputMu.Unlock()
	if s.inputDown {
		return
	}
	if s.inputConn == nil {
		path := s.hub.platform.inputSocketPath(s.hub.tile)
		conn, err := net.Dial("unix", path)
		if err != nil {
			s.inputDown = true
			log.Printf("webrtc-input: no daemon input socket tile=%s (%v); input dropped, video unaffected", s.hub.tile, err)
			return
		}
		if _, err := conn.Write([]byte(inputFeedMagic)); err != nil {
			_ = conn.Close()
			s.inputDown = true
			log.Printf("webrtc-input: handshake write failed tile=%s: %v", s.hub.tile, err)
			return
		}
		s.inputConn = conn
		log.Printf("webrtc-input: peer input connected tile=%s -> %s", s.hub.tile, path)
	}
	if _, err := s.inputConn.Write(encodeInputFrame(channel, data)); err != nil {
		_ = s.inputConn.Close()
		s.inputConn = nil
		s.inputDown = true
		log.Printf("webrtc-input: forward failed tile=%s: %v", s.hub.tile, err)
	}
}

func (s *peerSession) closeInput() {
	s.inputMu.Lock()
	defer s.inputMu.Unlock()
	if s.inputConn != nil {
		_ = s.inputConn.Close()
		s.inputConn = nil
	}
}
