// ============================================================================
//  streamClient/audioPlayer — Opus audio → WebAudio (latencyHint interactive).
//  ---------------------------------------------------------------------------
//  Encapsulates the whole audio pipeline that used to live inline on
//  StreamClient: the AudioDecoder, the AudioContext/GainNode, mute gating and
//  the play head. The only coupling back to StreamClient is an onError callback
//  (which mirrors what the inline code did: set stats.lastError). Behaviour is
//  identical — the method bodies are lifted verbatim.
// ============================================================================

import type { ByteReader } from './byteReader';

export class AudioPlayer {
  private audioDecoder: AudioDecoder | null = null;
  private audioCtx: AudioContext | null = null;
  private audioGain: GainNode | null = null;
  private audioEnabled = false;
  private playHead = 0;

  /** onError mirrors the original `this.stats.lastError = …` assignments. */
  constructor(private readonly onError: (msg: string) => void) {}

  async handleStream(br: ByteReader) {
    // Server framing (streamhost/src/transport.rs `send_audio`): ONE Opus packet
    // per uni-stream. The KIND_AUDIO byte is already consumed by handleStream; the
    // remainder of THIS stream is:
    //     [seq u32 LE][ts_us u32 LE][opus payload … to end of stream]
    // The wire is ALWAYS 48 kHz stereo Opus (audio.rs OUT_RATE / channels=2) — there
    // is NO per-stream sampleRate/channels preamble and NO length prefix. (The old
    // reader here assumed a single long-lived stream of length-prefixed packets with
    // a [sampleRate u32][channels u8] header — that stale format never matched the
    // production server, so it misread seq as the sample rate and decoded garbage,
    // silencing audio on every station.)
    const seq = await br.readU32LE();
    const tsUs = await br.readU32LE();
    if (seq == null || tsUs == null) return;
    const pkt = await br.readToEnd();
    if (!pkt.length) return;
    this.setupDecoder(48_000, 2);
    if (!this.audioDecoder) return;
    try {
      this.audioDecoder.decode(new EncodedAudioChunk({
        type: 'key', // Opus frames are independently decodable
        timestamp: tsUs, // server µs epoch (shared with the video capture ts)
        data: pkt,
      }));
    } catch (e) { this.onError(`adecode: ${String(e)}`); }
  }

  private setupDecoder(sampleRate: number, channels: number) {
    if (this.audioDecoder) return;
    const AudioCtor: typeof AudioContext | undefined =
      window.AudioContext ||
      (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (AudioCtor && !this.audioCtx) {
      try { this.audioCtx = new AudioCtor({ latencyHint: 'interactive', sampleRate }); }
      catch { try { this.audioCtx = new AudioCtor(); } catch { this.audioCtx = null; } }
      if (this.audioCtx) {
        this.audioGain = this.audioCtx.createGain();
        this.audioGain.gain.value = this.audioEnabled ? 1 : 0;
        this.audioGain.connect(this.audioCtx.destination);
      }
    }
    this.audioDecoder = new AudioDecoder({
      output: (data) => this.play(data),
      error: (e) => { this.onError(`adecode: ${String(e)}`); },
    });
    try {
      this.audioDecoder.configure({ codec: 'opus', sampleRate, numberOfChannels: channels });
    } catch (e) { this.onError(`aconfig: ${String(e)}`); }
  }

  private play(data: AudioData) {
    const ctx = this.audioCtx, gain = this.audioGain;
    if (!ctx || !gain || !this.audioEnabled) { try { data.close(); } catch { /* noop */ } return; }
    try {
      const channels = data.numberOfChannels;
      const frames = data.numberOfFrames;
      const buffer = ctx.createBuffer(channels, frames, data.sampleRate);
      for (let c = 0; c < channels; c++) {
        const plane = new Float32Array(frames);
        data.copyTo(plane, { planeIndex: c, format: 'f32-planar' });
        buffer.copyToChannel(plane, c);
      }
      const src = ctx.createBufferSource();
      src.buffer = buffer;
      src.connect(gain);
      const now = ctx.currentTime;
      if (this.playHead < now + 0.02) this.playHead = now + 0.02; // small anti-underrun lead
      src.start(this.playHead);
      this.playHead += buffer.duration;
    } catch (e) {
      this.onError(`aplay: ${String(e)}`);
    } finally {
      try { data.close(); } catch { /* noop */ }
    }
  }

  setEnabled(on: boolean) {
    this.audioEnabled = on;
    if (this.audioGain) this.audioGain.gain.value = on ? 1 : 0;
    if (on && this.audioCtx && this.audioCtx.state === 'suspended') {
      this.audioCtx.resume().catch(() => { /* needs a gesture */ });
    }
  }
  isEnabled(): boolean { return this.audioEnabled; }

  dispose() {
    try { this.audioDecoder?.close(); } catch { /* noop */ }
    this.audioDecoder = null;
    try { this.audioGain?.disconnect(); } catch { /* noop */ }
    this.audioGain = null;
    try { void this.audioCtx?.close().catch(() => { /* already closed */ }); } catch { /* noop */ }
    this.audioCtx = null;
  }
}
