// Original vector construction from the open 9300's silhouette and key layout.
// The panel is a true 3.2:1 rectangle; the reference illustration shortens it.
import { DEVICE_INK } from '../KeyCap';
import { JOY, SCREEN } from './keys';
import { NokiaWordmark } from './Wordmark';

export function Nokia9300Outline() {
  const s = SCREEN;
  return (
    <g stroke={DEVICE_INK} strokeWidth={3.5} fill="none" strokeLinejoin="round" strokeLinecap="round">
      {/* Both halves have the same bowed sides and broad, shallow corner curves. */}
      <path d="M137 523H1391Q1478 518 1493 562Q1515 648 1497 944Q1494 994 1456 1004
        Q768 1025 89 1004Q43 1000 38 953Q25 733 35 585Q39 524 91 523Z" fill="var(--dev-body)" />
      <path d="M141 534H1391Q1470 529 1480 567L1486 597L1499 603
        M35 603L51 599L58 567Q63 536 96 535H141
        M38 901L52 906L58 949Q61 983 96 989Q768 1014 1442 990Q1475 987 1480 952L1486 909L1499 902"
        strokeWidth={1.8} />
      <path d="M685 970V1003M851 970V1003M685 1003H851" strokeWidth={2} />
      {/* Speaker slots, with the dark inner slit visible in the drawing. */}
      {[568, 590].map((y) => (
        <g key={y}>
          <rect x={1377} y={y} width={77} height={11} rx={5} />
          <path d={`M1380 ${y + 5.5}H1451`} strokeWidth={1.5} />
        </g>
      ))}
      {/* Small concentric joystick, unlabelled as on the physical device. */}
      <path d="M1320 846Q1366 833 1410 846Q1422 852 1418 928Q1416 941 1403 942
        Q1366 949 1326 941Q1314 938 1314 925Q1310 862 1320 846Z" />
      {[JOY.r, 33, JOY.knob, 19].map((r) => (
        <circle key={r} cx={JOY.cx} cy={JOY.cy} r={r} strokeWidth={r === 19 ? 1.8 : 3} />
      ))}

      <path d="M126 29Q769 -5 1408 29Q1475 29 1489 94Q1511 264 1493 449
        Q1490 505 1451 509H89Q48 507 43 462Q24 277 43 116Q49 39 102 32Z"
        fill="var(--dev-body)" />
      <path d="M63 73Q60 91 85 82Q136 67 249 64Q768 42 1355 68Q1416 70 1453 81Q1474 87 1473 73"
        strokeWidth={2} />
      <path d="M78 104Q60 130 66 365L71 421Q73 443 96 450
        M54 459Q53 445 74 451Q105 461 144 463
        M1375 462Q1436 456 1463 448Q1481 442 1483 456" strokeWidth={1.4} />
      <rect x={696} y={34} width={143} height={11} rx={5.5} strokeWidth={2.5} />
      <rect x={s.x - 10} y={s.y - 9} width={s.w + 20} height={s.h + 18} rx={4} />
      <rect x={s.x - 1} y={s.y - 1} width={s.w + 2} height={s.h + 2} rx={1} strokeWidth={2.5} />
      <NokiaWordmark />

      {/* Tapered hinge barrels, with curved seams and a slim connecting spine. */}
      <path d="M442 500H1059V533H442Z" fill="var(--dev-body)" />
      <path d="M446 508H1056M702 500V533" strokeWidth={2} />
      <path d="M143 501Q184 485 242 489H399Q437 489 446 500V535Q432 548 392 548H218
        Q172 546 143 534Z" fill="var(--dev-body)" />
      <path d="M302 490Q291 516 300 547M145 520Q206 532 294 526H396Q426 526 443 520" strokeWidth={1.8} />
      <path d="M1058 500Q1073 486 1126 488H1298Q1343 488 1374 502V533
        Q1348 548 1285 548H1124Q1074 547 1058 534Z" fill="var(--dev-body)" />
      <path d="M1183 489Q1194 517 1183 547M1061 519Q1097 528 1185 524H1293Q1346 524 1371 519" strokeWidth={1.8} />
    </g>
  );
}
