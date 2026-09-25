// ============================================================================
//  nokia9300/Outline — the static line drawing of the open Communicator
//  ---------------------------------------------------------------------------
//  Drawn by hand in the drawing's viewBox units (1500 × 1010), from the 9300's
//  proportions: a lid carrying the 640x200 display with the command-button
//  column to its right, the two hinge barrels, and the keyboard half with its
//  speaker grille and joystick well. Everything a visitor can press is a
//  DeviceKey drawn on top of this; this layer is only the body.
// ============================================================================

import { DEVICE_INK } from '../KeyCap';
import { JOY, SCREEN } from './keys';

const line = { fill: 'none', stroke: DEVICE_INK, vectorEffect: 'non-scaling-stroke' as const };
const muted = { ...line, stroke: 'var(--dev-muted)' };

export function Nokia9300Outline() {
  const s = SCREEN;
  return (
    <g strokeLinejoin="round" strokeLinecap="round">
      {/* Keyboard half, drawn first so the hinge overlaps its top edge. */}
      <rect x={20} y={528} width={1460} height={472} rx={56} {...line} fill="var(--dev-body)" strokeWidth={2} />
      <rect x={36} y={544} width={1428} height={440} rx={44} {...muted} strokeWidth={1} />
      <path d="M690 1000V978Q690 970 698 970H802Q810 970 810 978V1000" {...line} strokeWidth={1.4} />
      {/* The keyboard well and the speaker grille right of the application row. */}
      <rect x={110} y={552} width={1346} height={412} rx={16} {...muted} strokeWidth={1} />
      <rect x={1392} y={566} width={58} height={11} rx={5.5} {...line} strokeWidth={1.2} />
      <rect x={1392} y={586} width={58} height={11} rx={5.5} {...line} strokeWidth={1.2} />
      {/* Joystick well: housing, ring and the centre knob. */}
      <rect x={JOY.cx - 74} y={JOY.cy - 74} width={148} height={148} rx={38}
        {...line} fill="var(--dev-key)" strokeWidth={1.4} />
      <circle cx={JOY.cx} cy={JOY.cy} r={JOY.r} {...line} strokeWidth={1.4} />
      <circle cx={JOY.cx} cy={JOY.cy} r={JOY.knob} {...line} strokeWidth={1.4} />
      <circle cx={JOY.cx} cy={JOY.cy} r={JOY.knob - 9} {...muted} strokeWidth={1} />

      {/* Lid. */}
      <rect x={20} y={10} width={1460} height={500} rx={62} {...line} fill="var(--dev-body)" strokeWidth={2} />
      <rect x={36} y={26} width={1428} height={468} rx={48} {...muted} strokeWidth={1} />
      <path d="M78 96Q62 260 78 424" {...muted} strokeWidth={1} />
      <rect x={695} y={30} width={110} height={12} rx={6} {...line} strokeWidth={1.4} />
      {/* Display glass and the panel itself (the live picture covers the panel). */}
      <rect x={s.x - 22} y={s.y - 22} width={s.w + 44} height={s.h + 44} rx={10} {...line} strokeWidth={1.6} />
      <rect x={s.x - 5} y={s.y - 5} width={s.w + 10} height={s.h + 10} rx={3} {...muted} strokeWidth={1} />
      <rect x={s.x} y={s.y} width={s.w} height={s.h} {...line} fill="#15171a" strokeWidth={1.2} />
      {/* Command-button column housing. */}
      <rect x={1298} y={s.y - 12} width={138} height={s.h + 24} rx={16} {...muted} strokeWidth={1} />
      <text x={720} y={489} textAnchor="middle" fontSize={30} fontWeight={700} letterSpacing={5}
        fill={DEVICE_INK}>NOKIA</text>

      {/* Hinge: two barrels and the bar between them. */}
      <rect x={458} y={512} width={584} height={30} rx={6} {...line} fill="var(--dev-body)" strokeWidth={1.6} />
      <path d="M750 512V542" {...line} strokeWidth={1.2} />
      {[128, 1042].map((hx) => (
        <g key={hx}>
          <rect x={hx} y={504} width={330} height={46} rx={23} {...line} fill="var(--dev-body)" strokeWidth={1.6} />
          <path d={`M${hx + 165} 506V548`} {...line} strokeWidth={1.2} />
          <path d={`M${hx + 22} 516H${hx + 308}`} {...muted} strokeWidth={1} />
        </g>
      ))}
    </g>
  );
}
