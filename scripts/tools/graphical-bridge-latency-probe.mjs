#!/usr/bin/env node
// Browser WebTransport round-trip probe for a graphical bridge marker client.
//
// The browser sends real type-1 absolute-pointer datagrams. The guest X probe
// moves its framebuffer marker; streamhost captures/encodes it; Chrome receives
// and decodes the first AU showing the target. Reported time is therefore
// browser-send -> guest input/composition -> QEMU capture -> encode/QUIC ->
// browser-decode/pixel, excluding only the final physical display scan-out.

import http from 'node:http';
import process from 'node:process';

function option(name, fallback = undefined) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1];
}

const url = option('--url');
const certHashB64 = option('--cert-hash');
const trials = Number(option('--trials', '12'));
const timeoutMs = Number(option('--timeout-ms', '3000'));
const codec = option('--codec', 'avc1.42e01e');
const detector = option('--detector', 'green');
const chromePath = option('--chrome', '/usr/bin/google-chrome');
const playwrightModule = option(
  '--playwright-module',
  'file:///usr/lib/node_modules/playwright/index.mjs',
);

if (!url || !certHashB64) {
  console.error(
    'usage: graphical-bridge-latency-probe.mjs --url https://HOST:PORT/wt ' +
      '--cert-hash BASE64 [--trials N]',
  );
  process.exit(2);
}

const pageSource = '<!doctype html><meta charset="utf-8"><title>graphical bridge latency probe</title>';
const server = http.createServer((_request, response) => {
  response.writeHead(200, { 'content-type': 'text/html' });
  response.end(pageSource);
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const localPort = server.address().port;

const { chromium } = await import(playwrightModule);
const browser = await chromium.launch({
  executablePath: chromePath,
  headless: true,
  args: ['--no-sandbox', '--disable-gpu'],
});

let result;
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${localPort}/`);
  result = await page.evaluate(
    async ({ certHashB64, codec, detector, timeoutMs, trials, url }) => {
      const certHash = Uint8Array.from(atob(certHashB64), (character) => character.charCodeAt(0));
      const wt = new WebTransport(url, {
        serverCertificateHashes: [{ algorithm: 'sha-256', value: certHash }],
        congestionControl: 'low-latency',
      });

      let audioPackets = 0;
      let audioSamples = 0;
      let audioSumSquares = 0;
      let audioPeak = 0;
      let audioDecoderError = null;
      let decodedFrames = 0;
      let decoderError = null;
      let width = 0;
      let height = 0;
      let pending = null;
      const canvas = new OffscreenCanvas(1, 1);
      const context = canvas.getContext('2d', { willReadFrequently: true });

      function findGreen(targetX, targetY) {
        const radius = 5;
        const left = Math.max(0, targetX - radius);
        const top = Math.max(0, targetY - radius);
        const right = Math.min(width, targetX + radius + 1);
        const bottom = Math.min(height, targetY + radius + 1);
        const image = context.getImageData(left, top, right - left, bottom - top);
        const hits = [];
        for (let offset = 0; offset < image.data.length; offset += 4) {
          const red = image.data[offset];
          const green = image.data[offset + 1];
          const blue = image.data[offset + 2];
          if (green > 100 && green > red + 45 && green > blue + 45) {
            const pixel = offset / 4;
            hits.push([left + (pixel % image.width), top + Math.floor(pixel / image.width)]);
          }
        }
        if (hits.length === 0) return null;
        return [
          Math.round(hits.reduce((sum, hit) => sum + hit[0], 0) / hits.length),
          Math.round(hits.reduce((sum, hit) => sum + hit[1], 0) / hits.length),
        ];
      }

      function cropAt(targetX, targetY, radius = 16) {
        const left = Math.max(0, targetX - radius);
        const top = Math.max(0, targetY - radius);
        const right = Math.min(width, targetX + radius + 1);
        const bottom = Math.min(height, targetY + radius + 1);
        return {
          image: context.getImageData(left, top, right - left, bottom - top),
          left,
          top,
        };
      }

      function wholeFrame() {
        return {
          image: context.getImageData(0, 0, width, height),
          left: 0,
          top: 0,
        };
      }

      function findDifference(current, baseline) {
        const hits = [];
        for (let offset = 0; offset < current.image.data.length; offset += 4) {
          const difference = Math.max(
            Math.abs(current.image.data[offset] - baseline.image.data[offset]),
            Math.abs(current.image.data[offset + 1] - baseline.image.data[offset + 1]),
            Math.abs(current.image.data[offset + 2] - baseline.image.data[offset + 2]),
          );
          if (difference > 35) {
            const pixel = offset / 4;
            hits.push([
              current.left + (pixel % current.image.width),
              current.top + Math.floor(pixel / current.image.width),
            ]);
          }
        }
        if (hits.length < 6) return null;
        return [
          Math.round(hits.reduce((sum, hit) => sum + hit[0], 0) / hits.length),
          Math.round(hits.reduce((sum, hit) => sum + hit[1], 0) / hits.length),
        ];
      }

      function findChange(targetX, targetY, baseline) {
        return findDifference(cropAt(targetX, targetY), baseline);
      }

      const decoder = new VideoDecoder({
        output(frame) {
          decodedFrames += 1;
          if (frame.displayWidth !== width || frame.displayHeight !== height) {
            width = frame.displayWidth;
            height = frame.displayHeight;
            canvas.width = width;
            canvas.height = height;
          }
          context.drawImage(frame, 0, 0);
          frame.close();
          if (pending) {
            let landing;
            if (detector === 'change') {
              landing = findChange(pending.target[0], pending.target[1], pending.baseline);
            } else if (detector === 'any-change') {
              landing = findDifference(wholeFrame(), pending.baseline);
            } else {
              landing = findGreen(pending.target[0], pending.target[1]);
            }
            if (landing) {
              const current = pending;
              pending = null;
              current.resolve({
                latencyMs: performance.now() - current.started,
                landing,
              });
            }
          }
        },
        error(error) {
          decoderError = String(error);
        },
      });
      decoder.configure({
        codec,
        optimizeForLatency: true,
        hardwareAcceleration: 'no-preference',
      });
      const audioDecoder =
        typeof AudioDecoder === 'undefined'
          ? null
          : new AudioDecoder({
              output(data) {
                try {
                  for (let channel = 0; channel < data.numberOfChannels; channel += 1) {
                    const samples = new Float32Array(data.numberOfFrames);
                    data.copyTo(samples, { format: 'f32-planar', planeIndex: channel });
                    for (const sample of samples) {
                      audioSumSquares += sample * sample;
                      audioPeak = Math.max(audioPeak, Math.abs(sample));
                    }
                    audioSamples += samples.length;
                  }
                } catch (error) {
                  audioDecoderError = String(error);
                } finally {
                  data.close();
                }
              },
              error(error) {
                audioDecoderError = String(error);
              },
            });
      audioDecoder?.configure({
        codec: 'opus',
        sampleRate: 48000,
        numberOfChannels: 2,
      });

      async function readAll(readable) {
        const reader = readable.getReader();
        const chunks = [];
        let length = 0;
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
          length += value.length;
        }
        const bytes = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) {
          bytes.set(chunk, offset);
          offset += chunk.length;
        }
        return bytes;
      }

      async function handleIncoming(readable) {
        const bytes = await readAll(readable);
        if (bytes[0] === 2) {
          audioPackets += 1;
          if (audioDecoder && bytes.length > 9) {
            const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
            audioDecoder.decode(
              new EncodedAudioChunk({
                type: 'key',
                timestamp: view.getUint32(5, true),
                data: bytes.subarray(9),
              }),
            );
          }
          return;
        }
        if (bytes[0] !== 1 || bytes.length <= 10) return;
        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        const frameId = view.getUint32(1, true);
        const isKey = bytes[5] === 1;
        const chunk = new EncodedVideoChunk({
          type: isKey ? 'key' : 'delta',
          timestamp: frameId * 1000,
          data: bytes.subarray(10),
        });
        decoder.decode(chunk);
      }

      const incomingReader = wt.incomingUnidirectionalStreams.getReader();
      const incomingLoop = (async () => {
        for (;;) {
          const { done, value } = await incomingReader.read();
          if (done) return;
          void handleIncoming(value);
        }
      })();

      await wt.ready;
      const datagrams = wt.datagrams.writable.getWriter();

      function sendAbs(x, y) {
        const bytes = new Uint8Array(5);
        const view = new DataView(bytes.buffer);
        bytes[0] = 1;
        view.setUint16(1, x, true);
        view.setUint16(3, y, true);
        return datagrams.write(bytes);
      }

      function waitFor(target) {
        return new Promise((resolve, reject) => {
          const started = performance.now();
          const timer = setTimeout(() => {
            if (pending?.started === started) pending = null;
            reject(new Error(`marker timeout at ${target}`));
          }, timeoutMs);
          pending = {
            baseline:
              detector === 'any-change'
                ? wholeFrame()
                : detector === 'change'
                  ? cropAt(target[0], target[1])
                  : null,
            target,
            started,
            resolve(value) {
              clearTimeout(timer);
              resolve(value);
            },
          };
        });
      }

      // Wait for the first decoded frame/geometry, then alternate between two
      // distant points so a stale frame can never satisfy the next trial.
      const geometryDeadline = performance.now() + timeoutMs * 2;
      while ((!width || !height) && performance.now() < geometryDeadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      if (!width || !height) throw new Error(`no decoded frame; decoder=${decoderError}`);
      const points = [
        [Math.round(width * 0.25), Math.round(height * 0.5)],
        [Math.round(width * 0.75), Math.round(height * 0.5)],
      ];

      const samples = [];
      // Seed at point 0 and require its decoded marker before timed trials.
      let detection = waitFor(points[0]);
      await sendAbs(...points[0]);
      await detection;
      await new Promise((resolve) => setTimeout(resolve, 150));

      for (let index = 0; index < trials; index += 1) {
        const target = points[(index + 1) % 2];
        detection = waitFor(target);
        await sendAbs(...target);
        const sample = await detection;
        samples.push({
          trial: index + 1,
          target,
          landing: sample.landing,
          latencyMs: Number(sample.latencyMs.toFixed(3)),
        });
        await new Promise((resolve) => setTimeout(resolve, 120));
      }

      wt.close();
      decoder.close();
      await audioDecoder?.flush().catch((error) => {
        audioDecoderError = String(error);
      });
      audioDecoder?.close();
      void incomingLoop;
      const latencies = samples.map((sample) => sample.latencyMs).sort((a, b) => a - b);
      const percentile = (fraction) => latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * fraction))];
      return {
        contract:
          detector === 'green'
            ? 'Chrome WebTransport send -> guest X marker -> Chrome WebCodecs pixel'
            : 'Chrome WebTransport send -> guest cursor change -> Chrome WebCodecs pixel',
        geometry: [width, height],
        trials: samples,
        p50Ms: percentile(0.5),
        p95Ms: percentile(0.95),
        minMs: latencies[0],
        maxMs: latencies.at(-1),
        decodedFrames,
        audioPackets,
        audioSamples,
        audioRms: audioSamples ? Number(Math.sqrt(audioSumSquares / audioSamples).toFixed(6)) : null,
        audioPeak: audioSamples ? Number(audioPeak.toFixed(6)) : null,
        audioDecoderError,
        decoderError,
      };
    },
    { certHashB64, codec, detector, timeoutMs, trials, url },
  );
} finally {
  await browser.close();
  server.close();
}

console.log(JSON.stringify(result, null, 2));
