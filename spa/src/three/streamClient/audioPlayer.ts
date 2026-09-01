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
import { noteAudioBlocked, noteAudioStart } from './analyticsEvents';

export class AudioPlayer {
  private audioDecoder: AudioDecoder | null = null;
  private audioCtx: AudioContext | null = null;
  private audioGain: GainNode | null = null;
  private audioEnabled = false;
  private playHead = 0;
  /** Session start, for `stream.audio.toFirstSampleMs`. The question that
   *  metric answers is the VISITOR's — how long after opening a machine does
   *  it make a sound — so it is measured from the moment this session's audio
   *  path exists, not from the first Opus packet (which would measure only the
   *  decoder, and would return zero on every sample). */
  private readonly createdAt = AudioPlayer.now();
  /** One-shots: the first sample heard, and the first sample that could not
   *  be. Independent, because a session blocked by autoplay policy and later
   *  unblocked by a gesture must report BOTH — reporting only the first would
   *  make every recovered session look permanently silent. */
  private reportedStart = false;
  private reportedBlocked = false;
  // ---- CONTINUOUS AUDIO VITALS (streamClient/vitals.ts) --------------------
  // Until these existed, audio continuity was UNFALSIFIABLE: the two one-shots
  // above are the entire audio telemetry this player has ever had, so a
  // session that fell silent thirty seconds in looked exactly like one that
  // played for an hour. Every counter below is read off a value the player
  // already computes; none of them costs a new measurement.
  /** Times the play head fell behind the context clock — see `play()`. Each
   *  one is a real gap the visitor heard, not a near miss. */
  private underruns = 0;
  /** Discontinuities in the server's Opus `seq`. The wire has carried a
   *  sequence number since the format was written and this player read it
   *  only to null-check it; a jump is the audio-side sibling of the video
   *  frame_id gap that `framesDropped` is counted from. */
  private seqGaps = 0;
  private lastSeq: number | null = null;
  /** AudioData frames scheduled, cumulative. The denominator for everything
   *  above: 2 underruns in 50 packets and 2 in 50,000 are different faults. */
  private framesPlayed = 0;
  /** Capture timestamp (server µs epoch) of the most recent packet scheduled.
   *  THE A/V SYNC OPERAND — the video side keeps the same stamp for the frame
   *  it last decoded, off the same clock. */
  private lastTsUs: number | null = null;

  private static now(): number {
    try { return typeof performance !== 'undefined' ? performance.now() : Date.now(); }
    catch { return Date.now(); }
  }

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
    // Sequence continuity. Compared with `!== last + 1` rather than `>` so a
    // RETRANSMIT (seq behind the newest) counts as a discontinuity too: the
    // question this answers is "did the audio arrive as an unbroken run", and
    // an out-of-order packet breaks the run whichever side of it it lands on.
    // Unsigned 32-bit wrap is left alone: it happens once per 4.3 billion
    // packets, i.e. never in a session, and special-casing it would be code
    // that can only ever be wrong.
    if (this.lastSeq != null && seq !== this.lastSeq + 1) this.seqGaps++;
    this.lastSeq = seq;
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
      // THIS BRANCH *IS* AN UNDERRUN, and counting it is the whole audio half
      // of the vitals lane. Reaching it means the play head — where the next
      // packet was going to be scheduled — had already been overtaken by the
      // context clock, i.e. the output ran out of buffered audio and the
      // visitor heard a gap. The clamp that follows papers over the gap for
      // the NEXT packet; nothing recorded that it happened.
      if (this.playHead < now + 0.02) { this.underruns++; this.playHead = now + 0.02; }
      src.start(this.playHead);
      this.playHead += buffer.duration;
      this.framesPlayed += frames;
      this.lastTsUs = data.timestamp;
      // The only proof this exhibit has audible sound. A configured decoder
      // and a scheduled buffer prove neither: a suspended context accepts both
      // and plays nothing, which is why the state is checked here rather than
      // at setup, and why the two one-shots below are independent.
      if (ctx.state === 'running') {
        if (!this.reportedStart) {
          this.reportedStart = true;
          noteAudioStart(AudioPlayer.now() - this.createdAt, data.sampleRate, ctx.state);
        }
      } else if (!this.reportedBlocked) {
        this.reportedBlocked = true;
        noteAudioBlocked(ctx.state, 'context-not-running');
      }
    } catch (e) {
      this.onError(`aplay: ${String(e)}`);
    } finally {
      try { data.close(); } catch { /* noop */ }
    }
  }

  /**
   * One tick's continuous audio vitals, or null when there is no audio path at
   * all (no AudioContext — the exhibit is silent by construction, and a row of
   * zeroes would claim we measured silence rather than nothing).
   *
   * `leadMs` is the PLAY-HEAD LEAD: how far ahead of the context clock the
   * scheduled audio reaches. It is the audio queue depth, and it is the number
   * an underrun threshold would fire on before the underrun happens — a lead
   * decaying toward the 20 ms floor is a stream about to break up, which the
   * underrun counter can only report afterwards.
   */
  vitals(): { running: number; leadMs: number; underruns: number; gaps: number;
              frames: number; tsUs: number | null } | null {
    const ctx = this.audioCtx;
    if (!ctx) return null;
    return {
      running: ctx.state === 'running' ? 1 : 0,
      leadMs: Math.max(0, (this.playHead - ctx.currentTime) * 1000),
      underruns: this.underruns,
      gaps: this.seqGaps,
      frames: this.framesPlayed,
      tsUs: this.lastTsUs,
    };
  }

  setEnabled(on: boolean) {
    this.audioEnabled = on;
    if (this.audioGain) this.audioGain.gain.value = on ? 1 : 0;
    if (on && this.audioCtx && this.audioCtx.state === 'suspended') {
      // A rejected resume is the autoplay policy saying no, and until now it
      // was swallowed here with a comment — the visitor watched a silent
      // machine and nothing outside their tab could ever know.
      this.audioCtx.resume().catch((e) => {
        if (this.reportedBlocked) return;
        this.reportedBlocked = true;
        noteAudioBlocked('suspended', e instanceof Error ? e.name : String(e));
      });
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
