import { DEVICE_INK } from '../KeyCap';
import { SCREEN } from './keys';

/** Original letterforms drawn against the open 9300 photographs: broad N/O,
 *  squared O counter, diagonal K, narrow I and flat-topped A. No font asset.
 *  190 × 30 master → 114 × 18 ink, centred on the display opening.
 *  The outer bezel's stroke ends at y=454.5: 18 units of air above the ink,
 *  then 7.75 units below it before the hinge's top stroke at y=498.25. */
export function NokiaWordmark() {
  return (
    <g data-device-wordmark="" aria-hidden="true"
      transform={`translate(${SCREEN.x + SCREEN.w / 2 - 57} 472.5) scale(.6)`}
      fill={DEVICE_INK} stroke="none" fillRule="evenodd"
    >
      {/* N */}
      <path d="M0 30V0H10L30 19V0H39V30H29L9 11V30Z" />
      {/* O: broad, nearly rectangular bowl and counter. */}
      <path d="M54 0H76Q86 0 86 10V20Q86 30 76 30H54Q44 30 44 20V10Q44 0 54 0Z
        M56 7Q53 7 53 10V20Q53 23 56 23H74Q77 23 77 20V10Q77 7 74 7Z" />
      {/* K, I */}
      <path d="M91 0H100V12L121 0H133L109 14.5L134 30H120L100 17V30H91Z" />
      <path d="M139 0H148V30H139Z" />
      {/* A: flat crown, open counter and heavy crossbar. */}
      <path d="M152 30L165 0H177L190 30H180L177.5 24H164.5L162 30Z
        M167 17H175L171 7Z" />
    </g>
  );
}
