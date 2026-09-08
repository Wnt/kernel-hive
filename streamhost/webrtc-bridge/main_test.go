package main

import (
	"net"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

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

// The remote path (docs/WEBRTC-PLATFORM.md §Remote visitors): with -public-ip
// the SDP must carry the public address AND the LAN address, both as host
// candidates on the ONE mux port. Replace mode would lose the LAN visitor;
// srflx mode would advertise an ephemeral port the edge does not forward.
func TestPublicIPIsAppendedOnTheMuxPort(t *testing.T) {
	udpConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer udpConn.Close()
	muxPort := udpConn.LocalAddr().(*net.UDPAddr).Port
	const public = "203.0.113.7" // RFC 5737 TEST-NET-3: never a real address

	settings, err := iceSettings(udpConn, public)
	if err != nil {
		t.Fatal(err)
	}
	gatherer, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewICEGatherer(webrtc.ICEGatherOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer gatherer.Close()
	done := make(chan struct{})
	gatherer.OnStateChange(func(s webrtc.ICEGathererState) {
		if s == webrtc.ICEGathererStateComplete {
			close(done)
		}
	})
	if err := gatherer.Gather(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("gathering never completed")
	}
	candidates, err := gatherer.GetLocalCandidates()
	if err != nil {
		t.Fatal(err)
	}
	sawPublic, sawLocal := false, false
	for _, c := range candidates {
		if c.Typ != webrtc.ICECandidateTypeHost {
			t.Errorf("candidate %s is %s, want every candidate to be host (srflx would leave the mux port)", c.Address, c.Typ)
		}
		if int(c.Port) != muxPort {
			t.Errorf("candidate %s advertises port %d, want the mux port %d", c.Address, c.Port, muxPort)
		}
		if c.Address == public {
			sawPublic = true
		} else {
			sawLocal = true
		}
	}
	if !sawPublic {
		t.Errorf("no candidate carries the public address %s: %+v", public, candidates)
	}
	if !sawLocal {
		t.Errorf("the LAN host candidate was replaced, not kept: %+v", candidates)
	}
}

func TestPublicIPMustParse(t *testing.T) {
	udpConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer udpConn.Close()
	if _, err := iceSettings(udpConn, "kernelhive.example"); err == nil {
		t.Fatal("a hostname was accepted as -public-ip; the unit must resolve it first")
	}
}
