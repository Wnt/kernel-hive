// Capitals-as-letters probe: drive the REAL SPA on a live station the way a
// visitor with Caps Lock / a paste tool / SendText does, then look at the
// station framebuffer (AGENTS.md rule 9). Nothing is decided here; an eye reads
// the PNGs. See docs/TYPE-IN-EDITOR.md "The case rule".
//
//   INVITE=<code> GALLERY_URL=... node caps-as-letters-probe.mjs <station> <outdir> [--restore]
//
// Frames:
//   1-nosh   `asdfghASDFGH` typed with NO Shift (keydown key 'A', no modifier)
//   2-caps   `ASDFGH` as keydown events with CapsLock on and no Shift (SendText style)
//   3-shift  physical Shift held, `A` `S`   (graphics glyphs on a VIC-20)
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { galleryUrl, inviteCode, openStation, shotDir, signIn } from './station-open.mjs';

const [id, outDir] = process.argv.slice(2);
const restore = process.argv.includes('--restore');
if (!id || !outDir) {
  console.error('usage: node caps-as-letters-probe.mjs <station> <outdir> [--restore]');
  process.exit(2);
}
const fb = (label) => {
  const path = `${outDir}/${id}-${label}.png`;
  execFileSync('ssh', ['-n', 'lab', `labctl shot ${id} ${path}`], { stdio: 'pipe', timeout: 60000 });
  console.log(`framebuffer ${label}: ${path}`);
};
const browser = await chromium.launch({
  headless: false,
  channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
});
try {
  const storageState = await signIn(browser, inviteCode(), `${shotDir()}/caps-${id}-state.json`);
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 }, storageState });
  const page = await ctx.newPage();
  const opened = await openStation(page, galleryUrl(), id, { direct: true, log: (m) => console.log(m) });
  if (!opened.ok) throw new Error(`station did not open: ${opened.why}`);
  const vbox = await page.locator('video').first().boundingBox();
  if (vbox) await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
  const settle = () => page.waitForTimeout(1500);
  await settle();
  fb('0-before');

  await page.keyboard.type('asdfghASDFGH', { delay: 150 });
  await settle();
  fb('1-nosh');

  await page.keyboard.press('Enter');
  for (const ch of 'ASDFGH') {
    await page.evaluate((k) => {
      const t = document.activeElement || document.body;
      const init = { key: k, code: `Key${k}`, bubbles: true, cancelable: true, modifierCapsLock: true };
      t.dispatchEvent(new KeyboardEvent('keydown', init));
      t.dispatchEvent(new KeyboardEvent('keyup', init));
    }, ch);
    await page.waitForTimeout(150);
  }
  await settle();
  fb('2-caps');

  await page.keyboard.press('Enter');
  await page.keyboard.down('Shift');
  await page.keyboard.press('KeyA');
  await page.keyboard.press('KeyS');
  await page.keyboard.up('Shift');
  await settle();
  fb('3-shift');

  if (restore) {
    await page.click('button[aria-label="Controls"]');
    const answered = page.waitForResponse(
      (r) => r.url().includes(`/restore/${id}`) && r.request().method() === 'POST', { timeout: 180000 });
    await page.getByRole('button', { name: /Restore to golden/ }).click();
    console.log(`restore POST: HTTP ${(await answered).status()}`);
    const back = await openStation(page, galleryUrl(), id, { direct: true, waitMs: 60000 });
    console.log(`restore: ${back.ok ? 'stream live again' : back.why}`);
    fb('4-restored');
  }
} finally {
  await browser.close();
}
