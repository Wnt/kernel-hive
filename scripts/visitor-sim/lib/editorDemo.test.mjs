// editorDemo.test.mjs — the pure pieces of the editor journey, verified
// without a browser. Run: node --test scripts/visitor-sim/lib/editorDemo.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  EDITOR_RECIPES,
  recipeFor,
  isExplicitlySupported,
  pickFunnyLine,
  randomClickPoints,
} from './editorDemo.mjs';

// A tiny deterministic RNG so the geometry is reproducible in tests.
function seq(values) {
  let i = 0;
  return () => values[i++ % values.length];
}

test('the six Windows stations are explicitly supported', () => {
  for (const id of ['win95', 'win98se', 'win2000', 'winxp', 'nt4', 'reactos']) {
    assert.equal(isExplicitlySupported(id), true, id);
    assert.ok(Array.isArray(EDITOR_RECIPES[id]), `${id} has a recipe`);
  }
});

test('an unknown station falls back to the default recipe, but is not "supported"', () => {
  assert.equal(isExplicitlySupported('helenos'), false);
  assert.equal(recipeFor('helenos'), recipeFor('win95')); // same shared array
});

test('every recipe opens Notepad via Ctrl+Esc then R (never the Windows key)', () => {
  for (const [id, recipe] of Object.entries(EDITOR_RECIPES)) {
    const presses = recipe.filter((s) => s.press).map((s) => s.press);
    assert.ok(presses.includes('Control+Escape'), `${id} uses Ctrl+Esc`);
    assert.ok(presses.includes('r'), `${id} presses r for Run`);
    assert.ok(
      !presses.some((p) => /Meta|Super/i.test(p)),
      `${id} must not use Meta/Super (collides with the driving browser)`,
    );
    assert.ok(
      recipe.some((s) => s.type === 'notepad'),
      `${id} types "notepad" into Run`,
    );
  }
});

test('pickFunnyLine is deterministic given rng and always returns a non-empty string', () => {
  assert.equal(pickFunnyLine(() => 0), pickFunnyLine(() => 0));
  assert.equal(typeof pickFunnyLine(() => 0.5), 'string');
  assert.ok(pickFunnyLine(() => 0.99).length > 0);
});

test('randomClickPoints returns n points, all inset inside the box', () => {
  const box = { x: 100, y: 50, width: 400, height: 300 };
  const pts = randomClickPoints(box, 5, seq([0, 0.25, 0.5, 0.75, 0.999]));
  assert.equal(pts.length, 5);
  const inset = 0.12;
  const minX = box.x + box.width * inset;
  const maxX = box.x + box.width * (1 - inset);
  const minY = box.y + box.height * inset;
  const maxY = box.y + box.height * (1 - inset);
  for (const p of pts) {
    assert.ok(p.x >= minX - 1e-9 && p.x <= maxX + 1e-9, `x ${p.x} in [${minX},${maxX}]`);
    assert.ok(p.y >= minY - 1e-9 && p.y <= maxY + 1e-9, `y ${p.y} in [${minY},${maxY}]`);
  }
});

test('randomClickPoints is deterministic given the same rng stream', () => {
  const box = { x: 0, y: 0, width: 200, height: 200 };
  const a = randomClickPoints(box, 3, seq([0.1, 0.4, 0.9]));
  const b = randomClickPoints(box, 3, seq([0.1, 0.4, 0.9]));
  assert.deepEqual(a, b);
});
