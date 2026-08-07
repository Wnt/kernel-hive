// Raw pointer recorder for a LIVE browser tab — the only way to see what a real
// stylus produces, since no synthetic probe reproduces a hand.
//
// Inject it through the operator eval plane (needs an admin session in the tab,
// or the operator token; see docs/lab/INPUT-DEBUGGING.md):
//
//   scp tests/e2e-live/pen-recorder.eval.js lab:/tmp/rec.js
//   ssh lab '/data/vms/streamhost/serve/clientcmd.sh sessions'
//   ssh lab 'OSG_ADMIN_EVAL=1 /data/vms/streamhost/serve/clientcmd.sh \
//              eval <sessionId> "$(cat /tmp/rec.js)"'
//
// Then read it back — NOTE the harness wraps code as an async function body, so
// a bare expression is discarded and every query must `return`:
//
//   # just the contacts (down/up), which is usually all you need
//   ssh lab 'OSG_ADMIN_EVAL=1 .../clientcmd.sh eval <id> \
//     "const r=window.__penRec; return JSON.stringify(r.filter(e=>e[0]!==\"m\"));"'
//   # …and the full stream inside the last contact
//   ssh lab 'OSG_ADMIN_EVAL=1 .../clientcmd.sh eval <id> "return JSON.stringify(window.__penRec.slice(-60));"'
//   ssh lab 'OSG_ADMIN_EVAL=1 .../clientcmd.sh evallog <id>'
//
// The result arrives via the telemetry batch (~5-10 s), not immediately.
//
// Row format, kept short because the whole buffer travels as one JSON string:
//   [type, timeStamp, pointerType, buttons, clientX, clientY]
//   type is the 8th char of the event name: d=down u=up m=move c=cancel
//   …plus X=contextmenu and A=auxclick, which carry no pointerType.
// Coordinates are CSS px — the unit a hand actually moves in. Divide the guest
// resolution by the surface's CSS width to convert (it is ~3.1 on IRIX).
//
// CONTEXTMENU IS RECORDED because on a Samsung S-Pen the barrel button has no
// pointer-button bit at all — it surfaces ONLY as a native contextmenu, and
// Android fires that same event for its own long-press gesture. The two are told
// apart by WHEN the contextmenu lands relative to the contact that is already
// running (input/penRightClick), so its timeStamp against the preceding `d` row
// is the whole diagnosis: an early one is the barrel, a late one is the OS.
// `now` (performance.now() read INSIDE the handler) is recorded next to the
// event's own timeStamp because on Chrome-Android they disagree in the one place
// it matters: a contextmenu synthesized from a long-press carries the SOURCE
// pointerdown's timeStamp, so `e.timeStamp - contactTimeStamp` is ~0 for a
// half-second hold. Only handler time says when the event actually arrived.
//
// Moves live in their OWN ring so a hover stream (~30/s) cannot evict the
// contacts and contextmenus — the first capture lost every interesting row that
// way and left one contact to reason from.
(() => {
  if (window.__penRec) {
    window.__penRec.length = 0;
    window.__penMoves.length = 0;
    return 'recorder reset';
  }
  const ev = [];        // contacts + contextmenu/auxclick — never evicted by moves
  const mv = [];        // the move stream, separately capped
  window.__penRec = ev;
  window.__penMoves = mv;
  const row = (tag, e) => [tag, Math.round(e.timeStamp), Math.round(performance.now()),
                           e.pointerType ? e.pointerType[0] : '-', e.buttons,
                           Math.round(e.clientX), Math.round(e.clientY)];
  const rec = (e) => {
    if (e.pointerType !== 'pen' && e.pointerType !== 'touch') return;
    if (e.type === 'pointermove') {
      mv.push(row('m', e));
      if (mv.length > 300) mv.shift();
      return;
    }
    ev.push(row(e.type[7], e));
    if (ev.length > 200) ev.shift();
  };
  for (const t of ['pointerdown', 'pointerup', 'pointermove', 'pointercancel']) {
    window.addEventListener(t, rec, true);
  }
  // Capture phase, so these are seen even though the app calls preventDefault.
  const mouse = (tag) => (e) => {
    ev.push(row(tag, e));
    if (ev.length > 200) ev.shift();
  };
  window.addEventListener('contextmenu', mouse('X'), true);
  window.addEventListener('auxclick', mouse('A'), true);
  return 'recording (rows: [tag, eventTs, handlerNow, ptrType, buttons, x, y]; '
    + 'd=down u=up c=cancel X=ctxmenu A=aux; moves in window.__penMoves)';
})()
