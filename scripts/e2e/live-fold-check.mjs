import { chromium } from 'playwright';
const b = await chromium.launch({ args: ['--no-sandbox','--ignore-certificate-errors'] });
const p = await (await b.newContext({ ignoreHTTPSErrors: true })).newPage();
await p.goto(process.argv[2], { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(4000);
const before = await p.evaluate(() => document.querySelectorAll('.os-card').length);
// open every collapsed era
await p.evaluate(() => {
  document.querySelectorAll('.era-toggle[aria-expanded="false"]').forEach(b => b.click());
});
await p.waitForTimeout(1500);
const after = await p.evaluate(() => ({
  cards: document.querySelectorAll('.os-card').length,
  eras: document.querySelectorAll('.era-section').length,
  sumCounts: [...document.querySelectorAll('.era-count')].reduce((n,e)=>n+parseInt(e.textContent,10),0),
}));
console.log('folded', before, 'expanded', JSON.stringify(after));
await b.close();
