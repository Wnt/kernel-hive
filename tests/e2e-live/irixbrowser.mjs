// Drive the LIVE irix tile through the deployed SPA in a real browser.
// Steps are echoed so the run is auditable; guest-side truth is read
// separately from the shm framebuffer over ssh.
import { chromium, firefox } from '@playwright/test';
import { execSync } from 'node:child_process';

const URL = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const ENGINE = process.env.ENGINE || 'firefox';

const cursor = () =>
  execSync(
    "ssh lab '/data/vms/streamhost/tiles/irix/fbstat.py --cursor /data/vms/streamhost/tiles/irix/fb.shm'",
  )
    .toString()
    .trim();
const shot = (n) =>
  execSync(
    `ssh lab '/data/vms/soltest/irix-wedge/shmshot.py /data/vms/streamhost/tiles/irix/fb.shm /tmp/live-${n}.png'`,
  ).toString().trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await (ENGINE === 'chromium' ? chromium : firefox).launch();
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1200 } });
const page = await ctx.newPage();
page.on('console', (m) => { if (m.type() === 'error') console.log('  [console]', m.text().slice(0, 160)); });

await page.goto(`${URL}/os/irix`, { waitUntil: 'domcontentloaded' });
await sleep(12000);
const surf = await page.evaluate(() => {
  const c = document.querySelector('canvas.sv-video');
  if (c) return { kind: 'canvas', w: c.width, h: c.height };
  const v = [...document.querySelectorAll('video')].find((x) => x.srcObject);
  return v ? { kind: 'video', w: v.videoWidth, h: v.videoHeight } : { kind: 'none' };
});
console.log('surface:', JSON.stringify(surf));

const el = await page.$('canvas.sv-video, video');
const box = await el.boundingBox();
console.log('surface box:', JSON.stringify(box));

// Map a guest pixel (of a 1288x1024 framebuffer) to a client point.
const G = { w: 1288, h: 1024 };
const pt = (gx, gy) => ({
  x: box.x + (box.width * (gx + 0.5)) / G.w,
  y: box.y + (box.height * (gy + 0.5)) / G.h,
});

console.log('cursor before any browser input:', cursor());
for (const [gx, gy] of [[644, 512], [322, 768], [966, 256], [644, 512]]) {
  const p = pt(gx, gy);
  await page.mouse.move(p.x, p.y, { steps: 12 });
  await sleep(2500);
  console.log(`  commanded guest (${gx},${gy}) -> measured ${cursor()}`);
}

const step = process.env.STEP || 'pointer';
if (step === 'login') {
  // The sweep above already left the pointer inside the iconlogin panel, and
  // X here is pointer-focus, so the field takes the keys.
  await page.keyboard.type('root', { delay: 220 });
  await sleep(1200);
  await page.keyboard.press('Enter');
  console.log('typed root + Enter;', shot('login'));
} else if (step === 'menu') {
  const p = pt(700, 520);
  await page.mouse.move(p.x, p.y, { steps: 10 });
  await sleep(1500);
  await page.mouse.down({ button: 'right' });
  await sleep(1500);
  console.log('right press:', shot('menu-open'), cursor());
  await sleep(2500);
  console.log('still held 4s later:', shot('menu-held'));
  const q = pt(800, 860);
  await page.mouse.move(q.x, q.y, { steps: 10 });
  await sleep(1500);
  console.log('dragged to item:', shot('menu-drag'), cursor());
  await page.mouse.up({ button: 'right' });
  await sleep(2500);
  console.log('released:', shot('menu-released'));
}

await browser.close();
