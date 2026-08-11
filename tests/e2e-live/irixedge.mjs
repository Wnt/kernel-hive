// Edge-slam stress through the real SPA: drive the pointer hard into every
// screen edge, then ask the guest whether it still moves.
import { firefox } from '@playwright/test';
import { execSync } from 'node:child_process';

const URL = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const cursor = () =>
  execSync(
    "ssh lab '/data/vms/streamhost/stations/irix/fbstat.py --cursor /data/vms/streamhost/stations/irix/fb.shm'",
  ).toString().trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await firefox.launch();
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 1200 } });
const page = await ctx.newPage();
await page.goto(`${URL}/os/irix`, { waitUntil: 'domcontentloaded' });
await sleep(12000);
const box = await (await page.$('canvas.sv-video, video')).boundingBox();
const inset = 3;
const corners = [
  ['top-left', box.x + inset, box.y + inset],
  ['bottom-right', box.x + box.width - inset, box.y + box.height - inset],
  ['top-right', box.x + box.width - inset, box.y + inset],
  ['bottom-left', box.x + inset, box.y + box.height - inset],
  ['centre', box.x + box.width / 2, box.y + box.height / 2],
];
for (let round = 1; round <= 3; round++) {
  for (const [name, x, y] of corners) {
    await page.mouse.move(x, y, { steps: 25 });
    await sleep(900);
    console.log(`round ${round} ${name.padEnd(13)} -> ${cursor()}`);
  }
}
console.log('--- after the stress, does an ordinary move still work?');
for (const [dx, dy] of [[-200, -150], [200, 150]]) {
  const p = { x: box.x + box.width / 2 + dx, y: box.y + box.height / 2 + dy };
  await page.mouse.move(p.x, p.y, { steps: 15 });
  await sleep(2000);
  console.log(`  move(${dx},${dy}) -> ${cursor()}`);
}
await browser.close();
