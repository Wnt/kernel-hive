// Parse the SPS VUI/DPB fields from a capture-aus.mjs JSON file.
// Usage: node parse-sps-vui.mjs ~/e2e/aus-freedos.json
import fs from 'node:fs';

const input = process.argv[2];
if (!input) throw new Error('usage: node parse-sps-vui.mjs <aus.json>');

class Bits {
  constructor(bytes) { this.bytes = bytes; this.bit = 0; }
  read(n = 1) {
    let value = 0;
    for (let i = 0; i < n; i++) {
      if (this.bit >= this.bytes.length * 8) throw new Error('truncated SPS');
      value = value * 2 + ((this.bytes[this.bit >> 3] >> (7 - (this.bit & 7))) & 1);
      this.bit++;
    }
    return value;
  }
  ue() {
    let zeros = 0;
    while (this.read() === 0) zeros++;
    return (2 ** zeros - 1) + (zeros ? this.read(zeros) : 0);
  }
  se() {
    const value = this.ue();
    return value & 1 ? (value + 1) / 2 : -(value / 2);
  }
}

function annexbNals(bytes) {
  const starts = [];
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] !== 0 || bytes[i + 1] !== 0) continue;
    if (bytes[i + 2] === 1) { starts.push([i, 3]); i += 2; }
    else if (bytes[i + 2] === 0 && bytes[i + 3] === 1) { starts.push([i, 4]); i += 3; }
  }
  return starts.map(([at, prefix], i) =>
    bytes.subarray(at + prefix, i + 1 < starts.length ? starts[i + 1][0] : bytes.length));
}

function rbsp(nal) {
  const out = [];
  for (let i = 1; i < nal.length; i++) {
    if (i + 2 < nal.length && nal[i] === 0 && nal[i + 1] === 0 && nal[i + 2] === 3) {
      out.push(0, 0); i += 2;
    } else out.push(nal[i]);
  }
  return Uint8Array.from(out);
}

function skipScalingList(b, size) {
  let last = 8, next = 8;
  for (let i = 0; i < size; i++) {
    if (next !== 0) next = (last + b.se() + 256) & 255;
    last = next === 0 ? last : next;
  }
}

function skipHrd(b) {
  const cpbCntMinus1 = b.ue();
  b.read(4); b.read(4);
  for (let i = 0; i <= cpbCntMinus1; i++) { b.ue(); b.ue(); b.read(); }
  b.read(5); b.read(5); b.read(5); b.read(5);
}

function parseSps(nal) {
  const bytes = rbsp(nal);
  const b = new Bits(bytes);
  const profileIdc = b.read(8);
  const constraints = b.read(8);
  const levelIdc = b.read(8);
  b.ue(); // seq_parameter_set_id
  if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profileIdc)) {
    const chromaFormatIdc = b.ue();
    if (chromaFormatIdc === 3) b.read();
    b.ue(); b.ue(); b.read();
    if (b.read()) {
      const count = chromaFormatIdc === 3 ? 12 : 8;
      for (let i = 0; i < count; i++) if (b.read()) skipScalingList(b, i < 6 ? 16 : 64);
    }
  }
  b.ue(); // log2_max_frame_num_minus4
  const picOrderCntType = b.ue();
  if (picOrderCntType === 0) b.ue();
  else if (picOrderCntType === 1) {
    b.read(); b.se(); b.se();
    const cycle = b.ue();
    for (let i = 0; i < cycle; i++) b.se();
  }
  const maxNumRefFrames = b.ue();
  b.read(); // gaps_in_frame_num_value_allowed_flag
  const picWidthInMbsMinus1 = b.ue();
  const picHeightInMapUnitsMinus1 = b.ue();
  const frameMbsOnly = b.read();
  if (!frameMbsOnly) b.read();
  b.read(); // direct_8x8_inference_flag
  if (b.read()) { b.ue(); b.ue(); b.ue(); b.ue(); }
  const vuiPresent = b.read() === 1;
  let bitstreamRestriction = false;
  let numReorderFrames = null;
  let maxDecFrameBuffering = null;
  if (vuiPresent) {
    if (b.read()) {
      const idc = b.read(8);
      if (idc === 255) { b.read(16); b.read(16); }
    }
    if (b.read()) b.read();
    if (b.read()) {
      b.read(3); b.read();
      if (b.read()) { b.read(8); b.read(8); b.read(8); }
    }
    if (b.read()) { b.ue(); b.ue(); }
    if (b.read()) { b.read(32); b.read(32); b.read(); }
    const nalHrd = b.read() === 1;
    if (nalHrd) skipHrd(b);
    const vclHrd = b.read() === 1;
    if (vclHrd) skipHrd(b);
    if (nalHrd || vclHrd) b.read();
    b.read(); // pic_struct_present_flag
    bitstreamRestriction = b.read() === 1;
    if (bitstreamRestriction) {
      b.read(); // motion_vectors_over_pic_boundaries_flag
      b.ue(); b.ue(); b.ue(); b.ue();
      numReorderFrames = b.ue();
      maxDecFrameBuffering = b.ue();
    }
  }
  return {
    profileIdc, constraints: `0x${constraints.toString(16).padStart(2, '0')}`,
    levelIdc, maxNumRefFrames, picOrderCntType,
    width: (picWidthInMbsMinus1 + 1) * 16,
    codedHeight: (picHeightInMapUnitsMinus1 + 1) * 16 * (2 - frameMbsOnly),
    vuiPresent, bitstreamRestriction, numReorderFrames, maxDecFrameBuffering,
    spsHex: Buffer.from(nal).toString('hex'),
  };
}

const aus = JSON.parse(fs.readFileSync(input, 'utf8'));
for (const au of aus) {
  const nals = annexbNals(Buffer.from(au.b64, 'base64'));
  const sps = nals.find((nal) => (nal[0] & 0x1f) === 7);
  if (!sps) continue;
  console.log(JSON.stringify({ frameId: au.frameId, ...parseSps(sps) }, null, 2));
  process.exit(0);
}
throw new Error('no SPS NAL found in capture');
