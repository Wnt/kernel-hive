// vitest port of scripts/test-annexb.mjs (kept as the framework-free
// `npm run test:annexb` sibling check). Synthetic AUs cover 4/3-byte start
// codes, multi-NAL access units, SPS/PPS/IDR key frames, and malformed input.
import { describe, expect, it } from 'vitest';
import {
  NAL_PPS, NAL_SPS,
  annexbToAvcc, buildAvcC, bytesEqual, codecFromSps, extractSpsPps, scanAnnexB,
} from './annexb';

const SC4 = [0, 0, 0, 1];
const SC3 = [0, 0, 1];
const u8 = (...parts: number[][]) => new Uint8Array(parts.flat());

const SPS = [0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40];
const PPS = [0x68, 0xeb, 0xe3, 0xcb, 0x22, 0xc0];
const SEI = [0x06, 0x05, 0x04, 0xaa, 0xbb, 0xcc, 0xdd, 0x80];
const IDR = [0x65, 0x88, 0x84, 0x00, 0x33, 0xff, 0xfe];
const SLICE_A = [0x41, 0x9a, 0x24, 0x6c, 0x41, 0x4f];
// Contains an emulation-prevented run 00 00 03 00 — must NOT split the NAL.
const SLICE_B = [0x41, 0x9a, 0x00, 0x00, 0x03, 0x00, 0x42, 0x77];

const beLen = (b: Uint8Array, o: number) => ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3];

describe('annexb NAL type constants', () => {
  it('SPS=7, PPS=8 (H.264 nal_unit_type)', () => {
    expect(NAL_SPS).toBe(7);
    expect(NAL_PPS).toBe(8);
  });
});

describe('scanAnnexB', () => {
  it('finds SPS+PPS+IDR in a key AU with mixed 4/3-byte start codes', () => {
    const au = u8(SC4, SPS, SC4, PPS, SC3, IDR);
    const nals = scanAnnexB(au);
    expect(nals.map((n) => n.type)).toEqual([7, 8, 5]);
    expect([...au.subarray(nals[2].start, nals[2].end)]).toEqual(IDR);
  });

  it('excludes the trailing zero of a following 4-byte start code from payload', () => {
    const au = u8(SC3, SLICE_A, SC4, SLICE_B);
    const nals = scanAnnexB(au);
    expect(nals).toHaveLength(2);
    expect([...au.subarray(nals[0].start, nals[0].end)]).toEqual(SLICE_A);
    expect([...au.subarray(nals[1].start, nals[1].end)]).toEqual(SLICE_B);
  });

  it('handles multiple slice NALs in one delta AU', () => {
    const nals = scanAnnexB(u8(SC4, SLICE_A, SC3, SLICE_B, SC3, SLICE_A));
    expect(nals.map((n) => n.type)).toEqual([1, 1, 1]);
  });

  it('never splits on an emulation-prevention run inside a NAL', () => {
    const au = u8(SC4, SLICE_B);
    const nals = scanAnnexB(au);
    expect(nals).toHaveLength(1);
    expect([...au.subarray(nals[0].start, nals[0].end)]).toEqual(SLICE_B);
  });

  it('returns [] for garbage / empty / no start code', () => {
    expect(scanAnnexB(u8([9, 9, 9, 9, 9]))).toEqual([]);
    expect(scanAnnexB(u8([]))).toEqual([]);
    expect(scanAnnexB(u8([0, 0]))).toEqual([]);
  });

  it('drops zero-length NALs from adjacent start codes', () => {
    const nals = scanAnnexB(u8(SC4, SC3, IDR));
    expect(nals).toHaveLength(1);
    expect(nals[0].type).toBe(5);
  });
});

describe('extractSpsPps', () => {
  it('returns copies that survive the source buffer being reused', () => {
    const au = u8(SC4, SPS, SC4, PPS, SC4, SEI, SC3, IDR);
    const { sps, pps } = extractSpsPps(au);
    expect([...sps!]).toEqual(SPS);
    expect([...pps!]).toEqual(PPS);
    au.fill(0);
    expect([...sps!]).toEqual(SPS);
  });

  it('returns nulls for a delta-only AU', () => {
    const { sps, pps } = extractSpsPps(u8(SC4, SLICE_A, SC3, SLICE_B));
    expect(sps).toBeNull();
    expect(pps).toBeNull();
  });
});

describe('buildAvcC', () => {
  it('produces the exact avcC record layout', () => {
    const rec = buildAvcC(new Uint8Array(SPS), new Uint8Array(PPS));
    expect(rec.length).toBe(5 + 1 + 2 + SPS.length + 1 + 2 + PPS.length);
    expect(rec[0]).toBe(0x01);
    expect(rec[4]).toBe(0xff); // reserved | lengthSizeMinusOne=3
    expect(rec[5]).toBe(0xe1); // reserved | numSPS=1
    expect([...rec.subarray(8, 8 + SPS.length)]).toEqual(SPS);
  });
});

describe('annexbToAvcc', () => {
  it('strips SPS/PPS, keeps SEI+IDR, u32-BE length prefixes', () => {
    const avcc = annexbToAvcc(u8(SC4, SPS, SC4, PPS, SC4, SEI, SC3, IDR));
    expect(avcc.length).toBe(4 + SEI.length + 4 + IDR.length);
    expect(beLen(avcc, 0)).toBe(SEI.length);
  });

  it('returns empty for a parameter-only or garbage AU', () => {
    expect(annexbToAvcc(u8(SC4, SPS, SC4, PPS)).length).toBe(0);
    expect(annexbToAvcc(u8([1, 2, 3, 4])).length).toBe(0);
  });
});

describe('codecFromSps / bytesEqual', () => {
  it('formats avc1.<profile><constraint><level> from SPS bytes 1..3', () => {
    expect(codecFromSps(new Uint8Array(SPS))).toBe('avc1.640028');
  });

  it('bytesEqual handles equality, inequality, and null-tolerance', () => {
    expect(bytesEqual(u8([1, 2, 3]), u8([1, 2, 3]))).toBe(true);
    expect(bytesEqual(u8([1, 2, 3]), u8([1, 2, 4]))).toBe(false);
    expect(bytesEqual(null, null)).toBe(true);
    expect(bytesEqual(u8([1]), null)).toBe(false);
  });
});
