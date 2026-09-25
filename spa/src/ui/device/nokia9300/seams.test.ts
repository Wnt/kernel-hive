import { describe, expect, it } from 'vitest';
import { NOKIA9300_KEYS } from './keys';

const box = (id: string) => NOKIA9300_KEYS.find((key) => key.id === id)!.box;
const edges = (id: string) => {
  const b = box(id);
  return [b.x, b.x + b.w];
};

describe('Nokia application and keyboard seams', () => {
  it('continues both edges of every application gap into a number-row gap exactly', () => {
    const apps = NOKIA9300_KEYS.filter((key) => key.id.startsWith('app.'));
    const numbers = ['esc', ...'1234567890'.split('').map((d) => `k${d}`), 'eq', 'bksp'];
    const numberGaps = numbers.slice(1).map((id, i) => [edges(numbers[i])[1], edges(id)[0]]);
    const appGaps = apps.slice(1).map((key, i) => [edges(apps[i].id)[1], edges(key.id)[0]]);
    expect(appGaps).toHaveLength(7);
    for (const gap of appGaps) expect(numberGaps).toContainEqual(gap);
    expect(appGaps.map(([left, right]) => (left + right) / 2))
      .toEqual([238, 442, 646, 748, 952, 1156, 1258]);
    expect(edges(apps[0].id)[0]).toBe(edges('esc')[0]);
    expect(edges(apps[apps.length - 1].id)[1]).toBe(edges('eq')[1]);
    expect(edges('esc')[0]).toBe(132.75);
    expect(edges('bksp')[1]).toBe(1461.25);
  });

  it('retains the photo layout of letter columns, the tall Enter and space-bar span', () => {
    for (const column of [
      ['esc', 'tab', 'caps', 'shift.l', 'ctrl'],
      ['k1', 'q', 'a', 'z', 'chr'], ['k2', 'w', 's', 'x', 'comma'],
      ['k3', 'e', 'd', 'c', 'period'], ['k4', 'r', 'f', 'v'],
      ['k5', 't', 'g', 'b'], ['k6', 'y', 'h', 'n'],
      ['k7', 'u', 'j', 'm', 'left'], ['k8', 'i', 'k', 'up', 'down'],
      ['k9', 'o', 'l', 'slash', 'right'], ['k0', 'p', 'semi', 'shift.r', 'menu'],
      ['eq', 'hash', 'quote'], ['bksp', 'enter'],
    ]) {
      for (const id of column) expect(edges(id), id).toEqual(edges(column[0]));
    }
    expect(edges('space')).toEqual([edges('v')[0], edges('n')[1]]);
    expect(box('enter').y).toBe(box('q').y);
    expect(box('enter').y + box('enter').h).toBe(box('a').y + box('a').h);
  });
});
