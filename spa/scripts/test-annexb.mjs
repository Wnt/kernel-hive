// ============================================================================
//  test-annexb.mjs — framework-free unit tests for src/three/annexb.ts
//  ---------------------------------------------------------------------------
//  Run: npm run test:annexb   (node --experimental-strip-types, no vitest —
//  annexb.ts is erasable-TS so node can strip and execute it directly).
//  Synthetic AUs cover: 4-byte + 3-byte start codes, multi-NAL (sliced-thread
//  slices), SPS+PPS+IDR key AUs, delta-only AUs, and malformed input.
// ============================================================================
import assert from 'node:assert/strict';
import {
  scanAnnexB, extractSpsPps, buildAvcC, annexbToAvcc, codecFromSps, bytesEqual,
} from '../src/three/annexb.ts';

const SC4 = [0, 0, 0, 1];
const SC3 = [0, 0, 1];
const u8 = (...parts) => new Uint8Array(parts.flat());

// Realistic-ish parameter sets: header byte 0x67 (SPS), 0x68 (PPS), 0x65 (IDR),
// 0x06 (SEI), 0x41 (non-IDR slice). SPS bytes 1..3 = profile/constraint/level.
const SPS = [0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40]; // High (100) / L4.0
const PPS = [0x68, 0xeb, 0xe3, 0xcb, 0x22, 0xc0];
const SEI = [0x06, 0x05, 0x04, 0xaa, 0xbb, 0xcc, 0xdd, 0x80];
const IDR = [0x65, 0x88, 0x84, 0x00, 0x33, 0xff, 0xfe];
const SLICE_A = [0x41, 0x9a, 0x24, 0x6c, 0x41, 0x4f];
// Contains an emulation-prevented run 00 00 03 00 — must NOT split the NAL.
const SLICE_B = [0x41, 0x9a, 0x00, 0x00, 0x03, 0x00, 0x42, 0x77];

let n = 0;
const ok = (name, fn) => { fn(); n++; console.log(`  ok ${n} — ${name}`); };

// ---- scanAnnexB -------------------------------------------------------------
ok('scan: SPS+PPS+IDR key AU, mixed 4/3-byte start codes', () => {
  const au = u8(SC4, SPS, SC4, PPS, SC3, IDR);
  const nals = scanAnnexB(au);
  assert.equal(nals.length, 3);
  assert.deepEqual(nals.map((x) => x.type), [7, 8, 5]);
  assert.deepEqual([...au.subarray(nals[0].start, nals[0].end)], SPS);
  assert.deepEqual([...au.subarray(nals[1].start, nals[1].end)], PPS);
  assert.deepEqual([...au.subarray(nals[2].start, nals[2].end)], IDR);
});

ok('scan: 4-byte code after a NAL — trailing zero is NOT payload', () => {
  const au = u8(SC3, SLICE_A, SC4, SLICE_B); // SLICE_A followed by 00 00 00 01
  const nals = scanAnnexB(au);
  assert.equal(nals.length, 2);
  assert.deepEqual([...au.subarray(nals[0].start, nals[0].end)], SLICE_A);
  assert.deepEqual([...au.subarray(nals[1].start, nals[1].end)], SLICE_B);
});

ok('scan: multi-NAL delta AU (sliced threads emit several slice NALs)', () => {
  const au = u8(SC4, SLICE_A, SC3, SLICE_B, SC3, SLICE_A);
  const nals = scanAnnexB(au);
  assert.equal(nals.length, 3);
  assert.deepEqual(nals.map((x) => x.type), [1, 1, 1]);
});

ok('scan: emulation-prevention bytes inside a NAL never split it', () => {
  const au = u8(SC4, SLICE_B);
  const nals = scanAnnexB(au);
  assert.equal(nals.length, 1);
  assert.deepEqual([...au.subarray(nals[0].start, nals[0].end)], SLICE_B);
});

ok('scan: garbage / no start code / empty → []', () => {
  assert.deepEqual(scanAnnexB(u8([9, 9, 9, 9, 9])), []);
  assert.deepEqual(scanAnnexB(u8([])), []);
  assert.deepEqual(scanAnnexB(u8([0, 0])), []);
});

ok('scan: adjacent start codes (zero-length NAL) are dropped', () => {
  const au = u8(SC4, SC3, IDR);
  const nals = scanAnnexB(au);
  assert.equal(nals.length, 1);
  assert.equal(nals[0].type, 5);
});

// ---- extractSpsPps ----------------------------------------------------------
ok('extractSpsPps: returns copies of the exact SPS/PPS bytes', () => {
  const au = u8(SC4, SPS, SC4, PPS, SC4, SEI, SC3, IDR);
  const { sps, pps } = extractSpsPps(au);
  assert.deepEqual([...sps], SPS);
  assert.deepEqual([...pps], PPS);
  au.fill(0); // copies must survive the AU buffer being reused
  assert.deepEqual([...sps], SPS);
});

ok('extractSpsPps: delta-only AU → nulls (annexb fallback trigger)', () => {
  const { sps, pps } = extractSpsPps(u8(SC4, SLICE_A, SC3, SLICE_B));
  assert.equal(sps, null);
  assert.equal(pps, null);
});

// ---- buildAvcC ---------------------------------------------------------------
ok('buildAvcC: exact record layout', () => {
  const sps = new Uint8Array(SPS), pps = new Uint8Array(PPS);
  const rec = buildAvcC(sps, pps);
  assert.equal(rec.length, 5 + 1 + 2 + SPS.length + 1 + 2 + PPS.length);
  assert.equal(rec[0], 0x01);                    // configurationVersion
  assert.equal(rec[1], SPS[1]);                  // profile
  assert.equal(rec[2], SPS[2]);                  // compat
  assert.equal(rec[3], SPS[3]);                  // level
  assert.equal(rec[4], 0xff);                    // 0xFC | lengthSizeMinusOne=3
  assert.equal(rec[5], 0xe1);                    // 0xE0 | numSPS=1
  assert.equal((rec[6] << 8) | rec[7], SPS.length);
  assert.deepEqual([...rec.subarray(8, 8 + SPS.length)], SPS);
  let o = 8 + SPS.length;
  assert.equal(rec[o++], 0x01);                  // numPPS=1
  assert.equal((rec[o] << 8) | rec[o + 1], PPS.length);
  assert.deepEqual([...rec.subarray(o + 2)], PPS);
});

// ---- annexbToAvcc -------------------------------------------------------------
const beLen = (b, o) => (b[o] << 24 >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3];

ok('annexbToAvcc: key AU strips SPS/PPS, keeps SEI(6) + IDR(5), u32-BE lengths', () => {
  const au = u8(SC4, SPS, SC4, PPS, SC4, SEI, SC3, IDR);
  const avcc = annexbToAvcc(au);
  assert.equal(avcc.length, 4 + SEI.length + 4 + IDR.length);
  assert.equal(beLen(avcc, 0), SEI.length);
  assert.deepEqual([...avcc.subarray(4, 4 + SEI.length)], SEI);
  const o = 4 + SEI.length;
  assert.equal(beLen(avcc, o), IDR.length);
  assert.deepEqual([...avcc.subarray(o + 4)], IDR);
});

ok('annexbToAvcc: multi-NAL delta AU — every NAL length-prefixed', () => {
  const au = u8(SC4, SLICE_A, SC3, SLICE_B, SC3, SLICE_A);
  const avcc = annexbToAvcc(au);
  assert.equal(avcc.length, 3 * 4 + 2 * SLICE_A.length + SLICE_B.length);
  assert.equal(beLen(avcc, 0), SLICE_A.length);
  const o2 = 4 + SLICE_A.length;
  assert.equal(beLen(avcc, o2), SLICE_B.length);
  assert.deepEqual([...avcc.subarray(o2 + 4, o2 + 4 + SLICE_B.length)], SLICE_B);
  const o3 = o2 + 4 + SLICE_B.length;
  assert.equal(beLen(avcc, o3), SLICE_A.length);
});

ok('annexbToAvcc: delta-only single NAL', () => {
  const avcc = annexbToAvcc(u8(SC4, SLICE_A));
  assert.equal(avcc.length, 4 + SLICE_A.length);
  assert.equal(beLen(avcc, 0), SLICE_A.length);
  assert.deepEqual([...avcc.subarray(4)], SLICE_A);
});

ok('annexbToAvcc: SPS+PPS-only AU / garbage → empty (caller must skip)', () => {
  assert.equal(annexbToAvcc(u8(SC4, SPS, SC4, PPS)).length, 0);
  assert.equal(annexbToAvcc(u8([1, 2, 3, 4])).length, 0);
  assert.equal(annexbToAvcc(u8([])).length, 0);
});

// ---- codecFromSps / bytesEqual ------------------------------------------------
ok('codecFromSps: avc1. + hex of SPS bytes 1..3 (real constraint flags)', () => {
  assert.equal(codecFromSps(new Uint8Array(SPS)), 'avc1.640028');
  assert.equal(codecFromSps(u8([0x67, 0x42, 0xe0, 0x1e])), 'avc1.42e01e');
  assert.equal(codecFromSps(u8([0x67, 0x4d, 0x00, 0x28])), 'avc1.4d0028');
});

ok('bytesEqual: equality, inequality, null handling', () => {
  assert.equal(bytesEqual(u8([1, 2, 3]), u8([1, 2, 3])), true);
  assert.equal(bytesEqual(u8([1, 2, 3]), u8([1, 2, 4])), false);
  assert.equal(bytesEqual(u8([1, 2]), u8([1, 2, 3])), false);
  assert.equal(bytesEqual(null, null), true);
  assert.equal(bytesEqual(u8([1]), null), false);
  assert.equal(bytesEqual(null, u8([1])), false);
});

// ---- round-trip sanity: tier change emits new SPS → bytes differ --------------
ok('cache-compare: a tier-changed SPS is detected as different', () => {
  const s1 = u8([0x67, 0x64, 0x00, 0x28, 0x01]);
  const s2 = u8([0x67, 0x64, 0x00, 0x1f, 0x01]); // level changed
  assert.equal(bytesEqual(s1, s2), false);
});

console.log(`\ntest-annexb: all ${n} assertions green`);
