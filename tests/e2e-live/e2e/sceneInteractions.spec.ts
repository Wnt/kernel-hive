import {
  devices,
  expect,
  test,
  type BrowserContext,
  type Page,
} from '@playwright/test';

interface ProjectedExhibit {
  id: string;
  row: number;
  sectionKey: string;
  ndc: [number, number];
}

interface FocusDebug {
  candidate: string | null;
  visible: Array<{ tileId: string; ndc: [number, number] }>;
}

interface CameraDebug {
  fov: number;
  position: [number, number, number];
}

const LANDSCAPE_FOV = 38;
const FOV_SPRING_TOLERANCE = 0.2;

declare global {
  interface Window {
    __museumExhibitDebug?: () => ProjectedExhibit[];
    __museumScreenFocusDebug?: () => FocusDebug;
    __museumCameraDebug?: () => CameraDebug;
    __museum?: {
      getState: () => {
        vms: Array<{ id: string; displayName: string }>;
      };
    };
  }
}

async function openScene(page: Page) {
  await page.goto('/museum?hallTest=2', { waitUntil: 'load' });
  await page.locator('canvas').waitFor({ state: 'visible' });
  await page.waitForFunction(() =>
    !!window.__museumExhibitDebug?.().length
    && !!window.__museumCameraDebug
    && !!window.__museumScreenFocusDebug?.().candidate,
    undefined,
    { timeout: 45_000 },
  );
}

async function canvasPoint(page: Page, ndc: [number, number]) {
  const box = await page.locator('canvas').boundingBox();
  expect(box).toBeTruthy();
  return {
    x: box!.x + (ndc[0] + 1) * box!.width / 2,
    y: box!.y + (1 - ndc[1]) * box!.height / 2,
  };
}

async function projectedDesk(page: Page) {
  return page.evaluate(() => {
    const focused = window.__museumScreenFocusDebug?.().candidate;
    const desks = window.__museumExhibitDebug?.() ?? [];
    const desk = desks.find(({ id }) => id === focused);
    if (!desk) throw new Error('focused exhibit has no projected desk position');
    const vm = window.__museum?.getState().vms.find(({ id }) => id === desk.id);
    if (!vm) throw new Error(`missing manifest title for ${desk.id}`);
    return { ...desk, title: vm.displayName };
  });
}

test('legacy museum2 deep links redirect to the promoted route', async ({ page }) => {
  await page.goto('/museum2?hallTest=2', { waitUntil: 'load' });
  await expect(page).toHaveURL(/\/museum\?hallTest=2$/);
  await expect(page.locator('canvas')).toBeVisible();
});

test('projected desk click opens the matching exhibit card', async ({ page }) => {
  await openScene(page);
  const desk = await projectedDesk(page);
  const point = await canvasPoint(page, desk.ndc);
  await page.mouse.click(point.x, point.y);

  const card = page.getByTestId('exhibit-info-card');
  await expect(card).toBeVisible();
  await expect(card.getByRole('heading', { level: 1 })).toHaveText(desk.title);
});

test('projected desk touch tap opens the matching exhibit card', async ({ browser }) => {
  const context: BrowserContext = await browser.newContext({
    ...devices['iPhone 13 landscape'],
    baseURL: process.env.GALLERY_URL || 'http://127.0.0.1:5238',
  });
  const page = await context.newPage();
  try {
    await openScene(page);
    const desk = await projectedDesk(page);
    const point = await canvasPoint(page, desk.ndc);
    await page.touchscreen.tap(point.x, point.y);

    const card = page.getByTestId('exhibit-info-card');
    await expect(card).toBeVisible();
    await expect(card.getByRole('heading', { level: 1 })).toHaveText(desk.title);
  } finally {
    await context.close();
  }
});

test('focused screen click still enters the OS session', async ({ page }) => {
  await openScene(page);
  const focused = await page.evaluate(() => {
    const state = window.__museumScreenFocusDebug?.();
    const tileId = state?.candidate;
    const screen = state?.visible.find((entry) => entry.tileId === tileId);
    if (!tileId || !screen) throw new Error('focused screen has no projection');
    return { tileId, ndc: screen.ndc };
  });
  const point = await canvasPoint(page, focused.ndc);
  await page.mouse.click(point.x, point.y);
  await expect(page).toHaveURL(new RegExp(`/os/${focused.tileId}$`));
  await page.mouse.move(2, 2);
  const exit = page.getByTitle('Back to the grid');
  await expect(exit).toBeVisible();
  await exit.click();
  await expect(page).toHaveURL(/\/museum\?hallTest=2$/);
  await expect(page.locator('canvas')).toBeVisible();
});

test('current-row hover zooms measurably and springs back', async ({ page }) => {
  await openScene(page);
  const focused = await page.evaluate(() => {
    const state = window.__museumScreenFocusDebug?.();
    const screen = state?.visible.find((entry) => entry.tileId === state.candidate);
    if (!screen) throw new Error('focused screen has no projection');
    return screen;
  });
  const point = await canvasPoint(page, focused.ndc);
  const before = await page.evaluate(() => window.__museumCameraDebug!());
  expect(Math.abs(before.fov - LANDSCAPE_FOV)).toBeLessThanOrEqual(
    FOV_SPRING_TOLERANCE,
  );

  await page.mouse.move(point.x, point.y);
  await expect.poll(
    () => page.evaluate(() => window.__museumCameraDebug!().fov),
  ).toBeLessThan(before.fov * 0.99);
  const zoomed = await page.evaluate(() => window.__museumCameraDebug!());
  expect(distance(zoomed.position, before.position)).toBeGreaterThan(0.002);

  await page.mouse.move(2, 2);
  await expect.poll(
    async () => Math.abs(
      await page.evaluate(() => window.__museumCameraDebug!().fov)
      - before.fov,
    ),
  ).toBeLessThanOrEqual(FOV_SPRING_TOLERANCE);
  const reverted = await page.evaluate(() => window.__museumCameraDebug!());
  expect(distance(reverted.position, before.position)).toBeLessThan(
    distance(zoomed.position, before.position) * 0.35,
  );
});

function distance(a: [number, number, number], b: [number, number, number]) {
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}
