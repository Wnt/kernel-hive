// ============================================================================
//  annexb — pure H.264 Annex-B helpers for the WebCodecs "avc" decode mode.
//  ---------------------------------------------------------------------------
//  Firefox's WebCodecs H.264 *annexb* path (no `description`, raw start-code
//  AUs) is broken (Bugzilla 1918769), so streamClient configures the decoder in
//  the spec's "avc" mode instead: an avcC `description` built from the in-band
//  SPS/PPS, plus AVCC (u32-BE length-prefixed) chunks. Chrome and Safari also
//  support this mode, so it is the SINGLE interoperable code path.
//
//  This module is deliberately framework-free and DOM-free (pure byte-wrangling
//  over Uint8Array) so it can be unit-tested under plain node:
//  `npm run test:annexb` → spa/scripts/test-annexb.mjs.
//
//  NOTE on 4-byte start codes: the scanner matches the 3-byte code 00 00 01 and
//  treats exactly ONE preceding 0x00 as part of a 4-byte code (00 00 00 01) —
//  i.e. that zero is NOT payload of the previous NAL. Deeper zero runs before a
//  start code (trailing_zero_8bits / cabac_zero_words) are left attached to the
//  previous NAL's payload, which decoders tolerate; x264 (our only producer,
//  b_annexb=1) never emits them.
//  Erasable-TS only (no enums/namespaces) so `node --experimental-strip-types`
//  can run it directly.
// ============================================================================

/** One NAL unit located inside an Annex-B access unit. `start`..`end` bound the
 *  payload (first byte = the NAL header), EXCLUDING the start code. */
export interface NalUnit {
  /** nal_unit_type — low 5 bits of the NAL header (7=SPS, 8=PPS, 6=SEI, 5=IDR). */
  type: number;
  /** payload start offset within the AU (the NAL header byte). */
  start: number;
  /** payload end offset (exclusive). */
  end: number;
}

export const NAL_SPS = 7;
export const NAL_PPS = 8;

/**
 * Scan an Annex-B access unit for NAL units. Handles 3-byte (00 00 01) and
 * 4-byte (00 00 00 01) start codes and MULTIPLE NALs per AU (x264 sliced
 * threads emit several slice NALs per frame). Zero-length NALs (adjacent start
 * codes) are dropped. Returns [] when no start code is found.
 */
export function scanAnnexB(au: Uint8Array): NalUnit[] {
  const nals: NalUnit[] = [];
  const n = au.length;
  let payloadStart = -1; // start of the NAL currently being accumulated
  let i = 0;
  while (i + 2 < n) {
    if (au[i] === 0 && au[i + 1] === 0 && au[i + 2] === 1) {
      if (payloadStart >= 0) {
        // Close the previous NAL. If the byte just before this start code is a
        // zero, it belongs to a 4-byte start code — exclude it from the payload.
        let end = i;
        if (end > payloadStart && au[end - 1] === 0) end--;
        if (end > payloadStart) {
          nals.push({ type: au[payloadStart] & 0x1f, start: payloadStart, end });
        }
      }
      payloadStart = i + 3;
      i += 3;
    } else if (au[i + 2] > 1) {
      // au[i+2] can be neither the 3rd byte of a start code (needs 0x01) nor
      // the 1st/2nd (needs 0x00) — the next candidate starts after it.
      i += 3;
    } else {
      i += 1;
    }
  }
  if (payloadStart >= 0 && au.length > payloadStart) {
    nals.push({ type: au[payloadStart] & 0x1f, start: payloadStart, end: au.length });
  }
  return nals;
}

/**
 * Extract the first SPS (type 7) and PPS (type 8) from an Annex-B key AU.
 * Returns COPIES (the AU buffer is transient wire memory). Either field is
 * null when absent — the caller then falls back to bare-annexb configure.
 */
export function extractSpsPps(au: Uint8Array): { sps: Uint8Array | null; pps: Uint8Array | null } {
  let sps: Uint8Array | null = null;
  let pps: Uint8Array | null = null;
  for (const nal of scanAnnexB(au)) {
    if (nal.type === NAL_SPS && !sps) sps = au.slice(nal.start, nal.end);
    else if (nal.type === NAL_PPS && !pps) pps = au.slice(nal.start, nal.end);
    if (sps && pps) break;
  }
  return { sps, pps };
}

/**
 * Synthesize an AVCDecoderConfigurationRecord (avcC box payload) from one SPS
 * and one PPS, for VideoDecoderConfig.description:
 *   [0x01, sps[1], sps[2], sps[3],          // version, profile, compat, level
 *    0xFC|3,                                 // lengthSizeMinusOne = 3 (u32 lengths)
 *    0xE0|1, u16BE len, SPS,                 // 1× SPS
 *    0x01,   u16BE len, PPS]                 // 1× PPS
 */
export function buildAvcC(sps: Uint8Array, pps: Uint8Array): Uint8Array {
  const out = new Uint8Array(5 + 1 + 2 + sps.length + 1 + 2 + pps.length);
  let o = 0;
  out[o++] = 0x01;      // configurationVersion
  out[o++] = sps[1];    // AVCProfileIndication
  out[o++] = sps[2];    // profile_compatibility (constraint flags)
  out[o++] = sps[3];    // AVCLevelIndication
  out[o++] = 0xfc | 3;  // reserved + lengthSizeMinusOne=3
  out[o++] = 0xe0 | 1;  // reserved + numOfSequenceParameterSets=1
  out[o++] = (sps.length >> 8) & 0xff;
  out[o++] = sps.length & 0xff;
  out.set(sps, o); o += sps.length;
  out[o++] = 1;         // numOfPictureParameterSets
  out[o++] = (pps.length >> 8) & 0xff;
  out[o++] = pps.length & 0xff;
  out.set(pps, o);
  return out;
}

/**
 * Convert one Annex-B AU to AVCC framing: every start code becomes a u32-BE
 * NAL length. NAL types 7 (SPS) and 8 (PPS) are STRIPPED — in avc mode they
 * live in the avcC description; everything else (SEI 6, slices, IDR 5) is
 * kept. Returns an empty array when the AU contains no (non-parameter) NALs —
 * the caller must skip feeding such a chunk.
 */
export function annexbToAvcc(au: Uint8Array): Uint8Array {
  const nals = scanAnnexB(au).filter((n) => n.type !== NAL_SPS && n.type !== NAL_PPS);
  let size = 0;
  for (const n of nals) size += 4 + (n.end - n.start);
  const out = new Uint8Array(size);
  let o = 0;
  for (const n of nals) {
    const len = n.end - n.start;
    out[o++] = (len >>> 24) & 0xff;
    out[o++] = (len >>> 16) & 0xff;
    out[o++] = (len >>> 8) & 0xff;
    out[o++] = len & 0xff;
    out.set(au.subarray(n.start, n.end), o);
    o += len;
  }
  return out;
}

/**
 * WebCodecs codec string derived from the REAL SPS bytes:
 * 'avc1.' + hex(profile_idc, constraint_flags, level_idc) — replaces the
 * hardcoded-constraint codecStringFor() for the avc-mode configure call.
 */
export function codecFromSps(sps: Uint8Array): string {
  const h = (b: number) => (b & 0xff).toString(16).padStart(2, '0');
  return `avc1.${h(sps[1])}${h(sps[2])}${h(sps[3])}`;
}

/** Byte-equality for cached SPS/PPS comparison; null-tolerant. */
export function bytesEqual(a: Uint8Array | null | undefined, b: Uint8Array | null | undefined): boolean {
  if (a == null || b == null) return a == null && b == null;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
