// osgallery-webrtc-bridge is one platform service for every streamhost tile.
// Each shared-binary streamhost instance registers its tile id on one Unix
// socket and mirrors its existing H.264 Annex-B AUs plus Opus packets. Offers
// are routed by tile id; there are no tile-specific bridge processes, ports,
// launchers, signal gates, or config files.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/interceptor"
	"github.com/pion/rtcp"
	"github.com/pion/rtp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	playoutDelayURI = "http://www.webrtc.org/experiments/rtp-hdrext/playout-delay"
	videoClockRate  = 90000
	maxRecordBytes  = 8 << 20
	feedMagic       = "OSGWB1"
	maxTileBytes    = 64
)

var tileRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

type options struct {
	socketPath string
	httpAddr   string
	udpPort    uint
	publicIP   string
	mtu        uint
	profile    string
}

type offerRequest struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

type answerResponse struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

type platform struct {
	videoCodec webrtc.RTPCodecCapability
	audioCodec webrtc.RTPCodecCapability
	mtu        uint16
	nextSSRC   atomic.Uint32
	hubsMu     sync.RWMutex
	hubs       map[string]*hub
}

type hub struct {
	tile       string
	platform   *platform
	packetizer rtp.Packetizer
	frames     atomic.Uint64
	audio      atomic.Uint64
	bytes      atomic.Uint64
	packets    atomic.Uint64
	peers      atomic.Int64
	connected  atomic.Int64
	lastTS     uint32
	tsMu       sync.Mutex
	feedMu     sync.Mutex
	feed       net.Conn
	sessionsMu sync.RWMutex
	sessions   map[*peerSession]struct{}
}

type peerSession struct {
	hub        *hub
	pc         *webrtc.PeerConnection
	videoTrack *webrtc.TrackLocalStaticRTP
	audioTrack *webrtc.TrackLocalStaticSample
	extID      atomic.Uint32
	stateMu    sync.Mutex
	connected  bool
	closed     bool
	closeOnce  sync.Once
}

func main() {
	var o options
	flag.StringVar(&o.socketPath, "socket", "/run/osgallery-webrtc/feeds.sock", "shared Unix socket for all tile feeds")
	flag.StringVar(&o.httpAddr, "http", "127.0.0.1:18080", "HTTP offer/health listen address")
	flag.UintVar(&o.udpPort, "udp-port", 55950, "shared fixed ICE UDP port")
	flag.StringVar(&o.publicIP, "public-ip", "", "optional 1:1-NAT candidate IP")
	flag.UintVar(&o.mtu, "mtu", 1188, "RTP packetizer MTU")
	flag.StringVar(&o.profile, "profile-level-id", "64001f", "platform H.264 SDP profile-level-id")
	flag.Parse()
	if o.socketPath == "" || o.udpPort == 0 || o.mtu < 576 || o.mtu > 1500 {
		flag.Usage()
		os.Exit(2)
	}

	videoCodec := webrtc.RTPCodecCapability{
		MimeType:    webrtc.MimeTypeH264,
		ClockRate:   videoClockRate,
		SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=" + o.profile,
		RTCPFeedback: []webrtc.RTCPFeedback{
			{Type: "nack"},
			{Type: "nack", Parameter: "pli"},
			{Type: "ccm", Parameter: "fir"},
		},
	}
	audioCodec := webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2,
		SDPFmtpLine: "minptime=10;useinbandfec=0",
	}
	p := &platform{
		videoCodec: videoCodec,
		audioCodec: audioCodec,
		mtu:        uint16(o.mtu),
		hubs:       make(map[string]*hub),
	}
	p.nextSSRC.Store(0x95000000)

	listener, err := listenUnix(o.socketPath)
	must(err)
	defer listener.Close()
	defer os.Remove(o.socketPath)
	go p.acceptFeeds(listener)

	api := mustAPI(o, videoCodec, audioCodec)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /offer/{tile}", p.handleOffer(api))
	mux.HandleFunc("GET /healthz", p.handleHealth)
	server := &http.Server{Addr: o.httpAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Printf("webrtc platform bridge ready http=%s ice=udp/%d socket=%s", o.httpAddr, o.udpPort, o.socketPath)
	must(server.ListenAndServe())
}

func mustAPI(o options, video, audio webrtc.RTPCodecCapability) *webrtc.API {
	mediaEngine := &webrtc.MediaEngine{}
	must(mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: video, PayloadType: 96,
	}, webrtc.RTPCodecTypeVideo))
	must(mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: audio, PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio))
	must(mediaEngine.RegisterHeaderExtension(
		webrtc.RTPHeaderExtensionCapability{URI: playoutDelayURI},
		webrtc.RTPCodecTypeVideo,
	))
	registry := &interceptor.Registry{}
	must(webrtc.RegisterDefaultInterceptors(mediaEngine, registry))
	settings := webrtc.SettingEngine{}
	udpConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4zero, Port: int(o.udpPort)})
	must(err)
	settings.SetICEUDPMux(ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: udpConn}))
	if o.publicIP != "" {
		settings.SetNAT1To1IPs([]string{o.publicIP}, webrtc.ICECandidateTypeHost)
	}
	return webrtc.NewAPI(
		webrtc.WithMediaEngine(mediaEngine),
		webrtc.WithInterceptorRegistry(registry),
		webrtc.WithSettingEngine(settings),
	)
}

func listenUnix(path string) (*net.UnixListener, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, err
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("refusing to remove non-socket %s", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	addr, err := net.ResolveUnixAddr("unix", path)
	if err != nil {
		return nil, err
	}
	return net.ListenUnix("unix", addr)
}

func (p *platform) acceptFeeds(listener *net.UnixListener) {
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			log.Printf("feed accept failed: %v", err)
			return
		}
		go p.serveFeed(conn)
	}
}

func (p *platform) serveFeed(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReaderSize(conn, 256<<10)
	magic := make([]byte, len(feedMagic))
	if _, err := io.ReadFull(r, magic); err != nil || string(magic) != feedMagic {
		log.Printf("rejected feed with invalid handshake")
		return
	}
	var lenBytes [2]byte
	if _, err := io.ReadFull(r, lenBytes[:]); err != nil {
		return
	}
	tileLen := int(binary.LittleEndian.Uint16(lenBytes[:]))
	if tileLen < 1 || tileLen > maxTileBytes {
		log.Printf("rejected feed with invalid tile length=%d", tileLen)
		return
	}
	tileBytes := make([]byte, tileLen)
	if _, err := io.ReadFull(r, tileBytes); err != nil {
		return
	}
	tile := string(tileBytes)
	if !validTile(tile) {
		log.Printf("rejected feed with invalid tile id")
		return
	}
	h := p.hub(tile)
	h.setFeed(conn)
	defer h.clearFeed(conn)
	log.Printf("tile feed connected tile=%s", tile)
	if err := h.readFeed(r); err != nil {
		log.Printf("tile feed ended tile=%s: %v", tile, err)
	}
}

func validTile(tile string) bool {
	return len(tile) <= maxTileBytes && tileRE.MatchString(tile)
}

func (p *platform) hub(tile string) *hub {
	p.hubsMu.RLock()
	h := p.hubs[tile]
	p.hubsMu.RUnlock()
	if h != nil {
		return h
	}
	p.hubsMu.Lock()
	defer p.hubsMu.Unlock()
	if h = p.hubs[tile]; h != nil {
		return h
	}
	ssrc := p.nextSSRC.Add(1)
	h = &hub{
		tile: tile, platform: p,
		packetizer: rtp.NewPacketizer(
			p.mtu, 96, ssrc, &codecs.H264Payloader{}, rtp.NewRandomSequencer(), videoClockRate,
		),
		sessions: make(map[*peerSession]struct{}),
	}
	p.hubs[tile] = h
	return h
}

func (p *platform) findHub(tile string) *hub {
	p.hubsMu.RLock()
	defer p.hubsMu.RUnlock()
	return p.hubs[tile]
}

func (h *hub) setFeed(conn net.Conn) {
	h.feedMu.Lock()
	old := h.feed
	h.feed = conn
	h.feedMu.Unlock()
	if old != nil && old != conn {
		_ = old.Close()
	}
	h.requestKeyframe()
	// A streamhost process may reconnect while peers survive. Re-establish every
	// active idle-pause lease on the new process so it cannot freeze under them.
	for i := int64(0); i < h.connected.Load(); i++ {
		h.sendCommand('S')
	}
}

func (h *hub) clearFeed(conn net.Conn) {
	h.feedMu.Lock()
	if h.feed == conn {
		h.feed = nil
	}
	h.feedMu.Unlock()
}

func (h *hub) hasFeed() bool {
	h.feedMu.Lock()
	defer h.feedMu.Unlock()
	return h.feed != nil
}

func (h *hub) readFeed(r *bufio.Reader) error {
	header := make([]byte, 4)
	for {
		if _, err := io.ReadFull(r, header); err != nil {
			return err
		}
		n := binary.LittleEndian.Uint32(header)
		if n < 2 || n > maxRecordBytes {
			return fmt.Errorf("invalid record size %d", n)
		}
		record := make([]byte, int(n))
		if _, err := io.ReadFull(r, record); err != nil {
			return err
		}
		switch record[0] {
		case 'V':
			if len(record) < 7 {
				return fmt.Errorf("short video record")
			}
			h.writeVideo(binary.LittleEndian.Uint32(record[1:5]), record[6:])
		case 'A':
			if len(record) < 10 {
				return fmt.Errorf("short audio record")
			}
			h.writeAudio(record[9:])
		default:
			return fmt.Errorf("unknown record kind")
		}
	}
}

func (h *hub) writeVideo(captureTS uint32, au []byte) {
	h.tsMu.Lock()
	deltaUS := uint32(33333)
	if h.lastTS != 0 {
		deltaUS = captureTS - h.lastTS
		if deltaUS < 1000 || deltaUS > 1_000_000 {
			deltaUS = 33333
		}
	}
	h.lastTS = captureTS
	samples := uint32((uint64(deltaUS) * videoClockRate) / 1_000_000)
	if samples == 0 {
		samples = 1
	}
	packets := h.packetizer.Packetize(au, samples)
	h.tsMu.Unlock()

	for _, packet := range packets {
		for _, session := range h.sessionSnapshot() {
			sessionPacket := *packet
			sessionPacket.Header = packet.Header.Clone()
			if extID := uint8(session.extID.Load()); extID != 0 {
				if err := sessionPacket.Header.SetExtension(extID, []byte{0x00, 0x00, 0x01}); err != nil {
					log.Printf("playout-delay extension failed tile=%s: %v", h.tile, err)
					session.extID.Store(0)
				}
			}
			if err := session.videoTrack.WriteRTP(&sessionPacket); err != nil && !errors.Is(err, io.ErrClosedPipe) {
				log.Printf("RTP video write failed tile=%s: %v", h.tile, err)
			}
		}
		h.packets.Add(1)
	}
	h.frames.Add(1)
	h.bytes.Add(uint64(len(au)))
}

func (h *hub) writeAudio(opus []byte) {
	for _, session := range h.sessionSnapshot() {
		if err := session.audioTrack.WriteSample(media.Sample{Data: opus, Duration: 20 * time.Millisecond}); err != nil && !errors.Is(err, io.ErrClosedPipe) {
			log.Printf("RTP audio write failed tile=%s: %v", h.tile, err)
		}
	}
	h.audio.Add(1)
}

func (h *hub) sessionSnapshot() []*peerSession {
	h.sessionsMu.RLock()
	defer h.sessionsMu.RUnlock()
	sessions := make([]*peerSession, 0, len(h.sessions))
	for session := range h.sessions {
		sessions = append(sessions, session)
	}
	return sessions
}

func (h *hub) registerSession(session *peerSession) {
	h.sessionsMu.Lock()
	h.sessions[session] = struct{}{}
	h.sessionsMu.Unlock()
	h.peers.Add(1)
}

func (s *peerSession) close() {
	s.closeOnce.Do(func() {
		s.stateMu.Lock()
		wasConnected := s.connected
		s.connected = false
		s.closed = true
		s.stateMu.Unlock()
		if wasConnected {
			s.hub.connected.Add(-1)
			s.hub.sendCommand('E')
		}
		s.hub.sessionsMu.Lock()
		delete(s.hub.sessions, s)
		s.hub.sessionsMu.Unlock()
		s.hub.peers.Add(-1)
		if s.pc != nil {
			go func() { _ = s.pc.Close() }()
		}
	})
}

func (s *peerSession) markConnected() bool {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	if s.closed || s.connected {
		return false
	}
	s.connected = true
	return true
}

func (s *peerSession) markDisconnected() bool {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	if !s.connected {
		return false
	}
	s.connected = false
	return true
}

var extmapRE = regexp.MustCompile(`(?mi)^a=extmap:([0-9]+)(?:/[a-z]+)?\s+` + regexp.QuoteMeta(playoutDelayURI) + `(?:\s|$)`)

func playoutExtensionID(sdp string) uint8 {
	m := extmapRE.FindStringSubmatch(sdp)
	if len(m) != 2 {
		return 0
	}
	n, err := strconv.Atoi(m[1])
	if err != nil || n < 1 || n > 14 {
		return 0
	}
	return uint8(n)
}

func (p *platform) handleOffer(api *webrtc.API) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tile, err := url.PathUnescape(r.PathValue("tile"))
		if err != nil || !validTile(tile) {
			http.Error(w, `{"error":"invalid tile"}`, http.StatusBadRequest)
			return
		}
		h := p.findHub(tile)
		if h == nil || !h.hasFeed() {
			http.Error(w, `{"error":"tile feed unavailable"}`, http.StatusServiceUnavailable)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 128<<10)
		defer r.Body.Close()
		var offer offerRequest
		if err := json.NewDecoder(r.Body).Decode(&offer); err != nil || offer.Type != "offer" || offer.SDP == "" {
			http.Error(w, `{"error":"invalid offer"}`, http.StatusBadRequest)
			return
		}
		pc, err := api.NewPeerConnection(webrtc.Configuration{})
		if err != nil {
			http.Error(w, `{"error":"peer creation failed"}`, http.StatusInternalServerError)
			return
		}
		videoTrack, err := webrtc.NewTrackLocalStaticRTP(p.videoCodec, "video", "osgallery-"+tile)
		if err != nil {
			_ = pc.Close()
			http.Error(w, `{"error":"video track failed"}`, http.StatusInternalServerError)
			return
		}
		audioTrack, err := webrtc.NewTrackLocalStaticSample(p.audioCodec, "audio", "osgallery-"+tile)
		if err != nil {
			_ = pc.Close()
			http.Error(w, `{"error":"audio track failed"}`, http.StatusInternalServerError)
			return
		}
		session := &peerSession{hub: h, pc: pc, videoTrack: videoTrack, audioTrack: audioTrack}
		h.registerSession(session)
		pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
			log.Printf("peer tile=%s state=%s playout-delay-ext=%d", tile, state, session.extID.Load())
			switch state {
			case webrtc.PeerConnectionStateConnected:
				if session.markConnected() {
					h.connected.Add(1)
					h.sendCommand('S')
				}
				h.requestKeyframe()
			case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
				session.close()
			case webrtc.PeerConnectionStateDisconnected:
				if session.markDisconnected() {
					h.connected.Add(-1)
					h.sendCommand('E')
				}
				time.AfterFunc(10*time.Second, func() {
					if pc.ConnectionState() == webrtc.PeerConnectionStateDisconnected {
						session.close()
					}
				})
			}
		})

		videoSender, err := pc.AddTrack(videoTrack)
		if err != nil {
			session.close()
			http.Error(w, `{"error":"video track failed"}`, http.StatusInternalServerError)
			return
		}
		audioSender, err := pc.AddTrack(audioTrack)
		if err != nil {
			session.close()
			http.Error(w, `{"error":"audio track failed"}`, http.StatusInternalServerError)
			return
		}
		go h.readVideoRTCP(videoSender)
		go drainRTCP(audioSender)
		if err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer.SDP}); err != nil {
			session.close()
			http.Error(w, `{"error":"remote offer rejected"}`, http.StatusBadRequest)
			return
		}
		answer, err := pc.CreateAnswer(nil)
		if err != nil {
			session.close()
			http.Error(w, `{"error":"answer creation failed"}`, http.StatusInternalServerError)
			return
		}
		gatherDone := webrtc.GatheringCompletePromise(pc)
		if err = pc.SetLocalDescription(answer); err != nil {
			session.close()
			http.Error(w, `{"error":"local answer rejected"}`, http.StatusInternalServerError)
			return
		}
		select {
		case <-gatherDone:
		case <-r.Context().Done():
			session.close()
			return
		case <-time.After(10 * time.Second):
			session.close()
			http.Error(w, `{"error":"ICE gathering timed out"}`, http.StatusGatewayTimeout)
			return
		}
		local := pc.LocalDescription()
		if local == nil {
			session.close()
			http.Error(w, `{"error":"answer unavailable"}`, http.StatusInternalServerError)
			return
		}
		session.extID.Store(uint32(playoutExtensionID(local.SDP)))
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(answerResponse{Type: "answer", SDP: local.SDP}); err != nil {
			session.close()
		}
	}
}

func (h *hub) readVideoRTCP(sender *webrtc.RTPSender) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		for _, packet := range packets {
			switch packet.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				h.requestKeyframe()
			}
		}
	}
}

func drainRTCP(sender *webrtc.RTPSender) {
	for {
		if _, _, err := sender.ReadRTCP(); err != nil {
			return
		}
	}
}

func (h *hub) requestKeyframe() {
	h.sendCommand('K')
}

func (h *hub) sendCommand(command byte) {
	h.feedMu.Lock()
	defer h.feedMu.Unlock()
	if h.feed != nil {
		_, _ = h.feed.Write([]byte{command})
	}
}

func (p *platform) handleHealth(w http.ResponseWriter, _ *http.Request) {
	type tileHealth struct {
		Feed               bool     `json:"feed"`
		Frames             uint64   `json:"frames"`
		AudioPackets       uint64   `json:"audioPackets"`
		Peers              int64    `json:"peers"`
		Connected          int64    `json:"connected"`
		PlayoutDelayExtIDs []uint32 `json:"playoutDelayExtIds"`
	}
	p.hubsMu.RLock()
	result := make(map[string]tileHealth, len(p.hubs))
	for tile, h := range p.hubs {
		result[tile] = tileHealth{
			Feed: h.hasFeed(), Frames: h.frames.Load(), AudioPackets: h.audio.Load(),
			Peers: h.peers.Load(), Connected: h.connected.Load(),
			PlayoutDelayExtIDs: h.playoutExtensionIDs(),
		}
	}
	p.hubsMu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "tiles": result})
}

func (h *hub) playoutExtensionIDs() []uint32 {
	seen := make(map[uint32]struct{})
	for _, session := range h.sessionSnapshot() {
		if id := session.extID.Load(); id != 0 {
			seen[id] = struct{}{}
		}
	}
	ids := make([]uint32, 0, len(seen))
	for id := range seen {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids
}

func must(err error) {
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func init() {
	if strings.TrimSpace(playoutDelayURI) == "" {
		panic("empty playout-delay URI")
	}
}
