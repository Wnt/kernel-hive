#!/usr/bin/env node

import { readdir, rename, rm, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(join(root, 'spa/package.json'));
const { Logger, NodeIO } = require('@gltf-transform/core');
const { ALL_EXTENSIONS } = require('@gltf-transform/extensions');
const {
  dedup,
  meshopt,
  prune,
  textureCompress,
} = require('@gltf-transform/functions');
const { MeshoptDecoder, MeshoptEncoder } = require('meshoptimizer');
const sharp = require('sharp');
const modelDir = join(root, 'spa/public/assets/models/v2/param');
const requested = new Set(process.argv.slice(2));
const files = (await readdir(modelDir))
  .filter((name) => name.endsWith('.glb') && (requested.size === 0 || requested.has(name)))
  .sort();

if (files.length === 0) {
  throw new Error(`No GLBs found in ${modelDir}`);
}

await Promise.all([MeshoptDecoder.ready, MeshoptEncoder.ready]);

const io = new NodeIO()
  .setLogger(new Logger(Logger.Verbosity.WARN))
  .registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({
    'meshopt.decoder': MeshoptDecoder,
    'meshopt.encoder': MeshoptEncoder,
  });

const rows = [];
for (const name of files) {
  const inputPath = join(modelDir, name);
  const outputPath = join(modelDir, `.${name}.optimize-${process.pid}.glb`);
  const before = (await stat(inputPath)).size;
  try {
    const document = await io.read(inputPath);
    await document.transform(
      dedup(),
      prune(),
      textureCompress({
        encoder: sharp,
        targetFormat: 'webp',
        resize: [1024, 1024],
        quality: 82,
        effort: 4,
      }),
      meshopt({ encoder: MeshoptEncoder, level: 'medium' }),
    );
    await io.write(outputPath, document);
    const after = (await stat(outputPath)).size;
    await rename(outputPath, inputPath);
    rows.push({ name, before, after });
  } finally {
    await rm(outputPath, { force: true });
  }
}

const totalBefore = rows.reduce((sum, row) => sum + row.before, 0);
const totalAfter = rows.reduce((sum, row) => sum + row.after, 0);
const table = [
  ...rows.map(({ name, before, after }) => ({
    Model: name,
    Before: formatBytes(before),
    After: formatBytes(after),
    Saved: formatPercent(before, after),
  })),
  {
    Model: 'TOTAL',
    Before: formatBytes(totalBefore),
    After: formatBytes(totalAfter),
    Saved: formatPercent(totalBefore, totalAfter),
  },
];

console.table(table);
console.log(`Optimized ${rows.length} GLBs in place: ${modelDir}`);

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${(bytes / 1024 ** 2).toFixed(2)} MiB`;
}

function formatPercent(before, after) {
  return `${((1 - after / before) * 100).toFixed(1)}%`;
}
