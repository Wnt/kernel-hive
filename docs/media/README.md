# docs/media — the README's demo clip

`demo.gif` is the first thing a stranger sees on GitHub, and the only claim it
has to make is **this museum is live and you can touch it**. A screenshot cannot
make that claim, and a video GitHub will not play cannot make it either (a
README inlines GIFs and essentially nothing else), so: a GIF, ten seconds,
recorded from the real public gallery rather than staged.

| file | what it is |
|---|---|
| `demo.gif` | 800x600, 95 frames at 10 fps, ~9.5 s — the clip the README opens with |
| `demo-poster.png` | one frame of it (Program Manager's File menu open), for anywhere the GIF is too heavy |

**What is on screen:** the collection at `kernelhive.madekivi.fi`; a card
clicked; `Waiting for desktop… 1990 · Windows 3.11`; the Windows 3.11 desktop
arriving; the pointer crossing it to Program Manager's **File** menu; the menu
unfolding; the pointer running down it to `Run…`; and the Run dialog painting
itself into existence. Every pointer move and both clicks came from a browser
over the internet. Nothing is launched and nothing is typed, so the station is
left exactly as it was found.

## How it was recorded

`scripts/e2e/readme-demo-capture.mjs`, from CT950, against the **public**
gallery — the same three gates a stranger meets (`docs/PUBLIC-GALLERY.md`) —
signed in with the standing viewer invite:

```sh
cp scripts/e2e/readme-demo-capture.mjs scripts/e2e/station-open.mjs ~/e2e/
cd ~/e2e
DISPLAY=:1 INVITE=/data/vms/streamhost/serve/pki/sim-invite.code \
  OUT=~/e2e/demo node readme-demo-capture.mjs win311
```

It records the **page viewport only** (Playwright `recordVideo`) — no browser
chrome, no address bar, so no internal host or address can reach a frame
(`AGENTS.md` rule 1). `RECON=1` lands on the live desktop and takes one
screenshot, which is how new guest coordinates are read off; `SHOTS=1` drops a
PNG at every beat.

Two things in that script are not stylistic and should survive any edit:

* **Nothing waits on a guessed sleep.** Every pause is a `settle`: the decoded
  frame is fingerprinted at 96x72 and the beat waits for it to move and then to
  stop moving. This is `AGENTS.md` rule 14, and it is load-bearing here — on a
  busy box the guest ran EIGHT SECONDS behind the host, and a fixed dwell once
  sent a click meant for `Run…` into a menu that was still open, so Program
  Manager asked whether to **delete a program group**. It was cancelled and
  nothing was lost; a capture that can do that to a live station must not use
  sleeps. The `settle` metric counts pixels that changed by more than 30, not a
  mean: a live H.264 stream dithers a static desktop forever, so a mean-based
  test never reports quiet and every wait times out.
* **The station is left as found.** The scene has no click after the menu opens
  except the one on `Run…`, and it ends on Escape.

## How the GIF is cut from the recording

Four segments, two crops. The station picture is letterboxed inside a
viewport-sized `<video>` (the capture logs `picture: 1080x810 at 180,0`), so the
station segments are cropped to the picture and the collection segment is
cropped from the left edge, where the gallery's own header is. Both land on the
same canvas, so they concatenate without padding.

```sh
FF=~/.cache/ms-playwright/ffmpeg-1011/ffmpeg-linux   # Playwright ships one
$FF -ss 5.2  -t 1.25 -i page@*.webm -r 6 -vf "crop=1020:765:0:0,scale=800:600"   -f image2 f/a%03d.png
$FF -ss 7.45 -t 1.4  -i page@*.webm -r 6 -vf "crop=1020:765:180:0,scale=800:600" -f image2 f/b%03d.png
$FF -ss 11.0 -t 10.0 -i page@*.webm -r 6 -vf "crop=1020:765:180:0,scale=800:600" -f image2 f/c%03d.png
$FF -ss 40.6 -t 2.6  -i page@*.webm -r 6 -vf "crop=1020:765:180:0,scale=800:600" -f image2 f/d%03d.png
convert -delay 10 -loop 0 f/*.png -layers OptimizeFrame -colors 128 demo.gif
```

Sampling at 6 fps and playing at 10 fps retimes the clip to about 1.7x, which is
deliberate: the dwells in the capture wait for the guest, and the box was at a
load average of 18 on 16 cores while four bring-up waves ran. Every frame in the
GIF is a real captured frame — nothing is interpolated, reordered or re-staged;
the cuts between segments are the only editing.

**What the crop removes**, and why that is the honest framing rather than the
flattering one: the crop drops the letterbox margins and with them the SPA's
top-right corner, which intermittently carried the client-side `Device under
load` banner (`spa/src/ui/grid/StreamView/useDevicePressure.ts`). That banner
was measuring the CAPTURE rig — a headed Chrome on software GL, encoding a
video, on a loaded box — not the museum.

## What this capture found, and why the clip has no typing in it

The scene originally typed a line into the Run dialog. It never landed intact:
across four recordings the field read `nel hive`, `nel h`, `nel hiv` — the
**opening characters of a keystroke burst are dropped** on this station's input
path, two to seven of them, and the loss survived a 45-second wait for the
dialog to finish painting and a six-press `ArrowRight` warm-up meant to absorb
it. So the clip ends on the dialog appearing, which is a real response to a real
click, rather than on a word with its head bitten off. The drop itself belongs
with the other input findings — `docs/lab/INPUT-DEBUGGING.md`.

## Re-recording it

Any station with a `SCENES` entry works, and adding one is a `RECON=1` run plus
guest coordinates. Keep the result under **8 MB** — GitHub stops inlining above
that — and the poster under 400 KB.
