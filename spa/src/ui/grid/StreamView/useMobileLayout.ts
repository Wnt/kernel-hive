// Mobile-LAYOUT gate for the OS view's three-region restructure (thin bar /
// maximized stage / keyboard sheet). Deliberately DIFFERENT from
// env.isTouchDevice() (any-pointer, serves the zoom gate): the layout swap
// keys on the PRIMARY pointer being coarse, so a touchscreen laptop keeps the
// full desktop toolbar while its touch zoom still works.

import { useEffect, useState } from 'react';

/** Pure predicate (unit-tested): mobile layout ⇔ TouchEvent AND primary-coarse. */
export function isMobileLayout(i: { touch: boolean; coarsePrimary: boolean }): boolean {
  return i.touch && i.coarsePrimary;
}

const QUERY = '(pointer: coarse)';

function read(): boolean {
  if (typeof window === 'undefined') return false;
  return isMobileLayout({
    touch: !!(window as unknown as { TouchEvent?: unknown }).TouchEvent,
    coarsePrimary: !!window.matchMedia && window.matchMedia(QUERY).matches,
  });
}

export function useMobileLayout(): boolean {
  const [mobile, setMobile] = useState(read);
  useEffect(() => {
    if (!window.matchMedia) return;
    const mql = window.matchMedia(QUERY);
    const onChange = () => setMobile(read());
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, []);
  return mobile;
}
