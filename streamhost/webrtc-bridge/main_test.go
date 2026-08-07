package main

import "testing"

func TestPlayoutExtensionID(t *testing.T) {
	sdp := "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n" +
		"a=extmap:5 " + playoutDelayURI + "\r\n"
	if got := playoutExtensionID(sdp); got != 5 {
		t.Fatalf("got extension id %d, want 5", got)
	}
}

func TestPlayoutExtensionIDDirection(t *testing.T) {
	sdp := "a=extmap:12/recvonly " + playoutDelayURI + "\r\n"
	if got := playoutExtensionID(sdp); got != 12 {
		t.Fatalf("got extension id %d, want 12", got)
	}
}

func TestPlayoutExtensionIDAbsentOrTwoByte(t *testing.T) {
	for _, sdp := range []string{
		"a=extmap:5 urn:ietf:params:rtp-hdrext:toffset\r\n",
		"a=extmap:15 " + playoutDelayURI + "\r\n",
	} {
		if got := playoutExtensionID(sdp); got != 0 {
			t.Fatalf("got extension id %d, want disabled", got)
		}
	}
}

func TestSessionExtensionIDsAreIndependent(t *testing.T) {
	h := &hub{sessions: make(map[*peerSession]struct{})}
	first := &peerSession{}
	first.extID.Store(5)
	second := &peerSession{}
	second.extID.Store(12)
	h.sessions[first] = struct{}{}
	h.sessions[second] = struct{}{}

	got := h.playoutExtensionIDs()
	if len(got) != 2 || got[0] != 5 || got[1] != 12 {
		t.Fatalf("got active extension ids %v, want [5 12]", got)
	}
}

func TestSessionRemovalIsIdempotent(t *testing.T) {
	h := &hub{sessions: make(map[*peerSession]struct{})}
	session := &peerSession{hub: h, connected: true}
	h.registerSession(session)
	h.connected.Store(1)

	session.close()
	session.close()

	if got := h.peers.Load(); got != 0 {
		t.Fatalf("got %d peers after repeated removal, want 0", got)
	}
	if got := len(h.sessionSnapshot()); got != 0 {
		t.Fatalf("got %d sessions after removal, want 0", got)
	}
	if got := h.connected.Load(); got != 0 {
		t.Fatalf("got %d connected peers after repeated removal, want 0", got)
	}
	if session.markConnected() {
		t.Fatal("closed session was marked connected again")
	}
}

func TestValidTile(t *testing.T) {
	for _, tile := range []string{"win95", "solaris", "redstar2", "tile.test-1"} {
		if !validTile(tile) {
			t.Fatalf("valid tile rejected: %q", tile)
		}
	}
	for _, tile := range []string{"", "../win95", "win95/offer", "space tile"} {
		if validTile(tile) {
			t.Fatalf("invalid tile accepted: %q", tile)
		}
	}
}

func TestPlatformHubsArePerTile(t *testing.T) {
	p := &platform{
		mtu:  1188,
		hubs: make(map[string]*hub),
	}
	a := p.hub("win95")
	b := p.hub("freedos")
	if a == b || a.tile != "win95" || b.tile != "freedos" {
		t.Fatalf("tile hubs were not independent: a=%p/%q b=%p/%q", a, a.tile, b, b.tile)
	}
	if again := p.hub("win95"); again != a {
		t.Fatal("same tile did not reuse its platform hub")
	}
}
