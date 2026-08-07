# Declarative installer vision

`install-vision` runs ordered YAML flows against a QEMU framebuffer. It reuses
the toolkit's Tesseract text matching, multi-scale OpenCV templates, relative
ROIs, frame settling, and QMP input/screendump plumbing. Use it only with a
namespaced build/clone QMP socket, never a live tile. The CLI fails closed
unless `--qmp` resolves below `/data/vms/soltest`; set
`CLONE_GUARD_CLONE_ROOT` only when the clone guard uses a different sandbox.

Install the CPU-only dependencies once per checkout:

```bash
sudo apt-get install -y tesseract-ocr python3-venv python3-tk
scripts/install-vision/install.sh
```

## Read-only production assertions

`labctl assert` reuses the same primitives for production health checks without
injecting input or resuming an idle-paused guest:

```bash
labctl assert helenos --text "HelenOS"
labctl assert android --template \
  /data/vms/streamhost/build/scripts/install-vision/templates/android/start.png
labctl assert helenos --settle
```

These forms take QMP screendumps only. They never click, type, reset, or issue
`cont`. Flow driving remains clone-only.

## Run a flow

Run a flow and retain its PNG/JSON evidence:

```bash
REDSTAR3_PASSWORD='<from the credential store>' \
  scripts/install-vision/install-vision run \
  scripts/install-vision/redstar3.flow.yaml \
  --qmp /data/vms/soltest/my-redstar3-clone/qmp.sock \
  --work-dir /data/vms/soltest/my-redstar3-clone/vision-evidence
```

The final JSON summary is also written to `WORK_DIR/run.json`. Progress logs
contain only the step name, action, and result. Values substituted from the
environment are never included in progress or audit records. Do not put a
checkpoint on a screen that renders a secret as clear text; password bullets
are safe, but a visible product-key field is not.

## Flow schema

A flow has `version: 1`, an optional human-readable `name`, a `fixtures_dir`
relative to the YAML file, optional defaults, and a non-empty ordered `steps`
list. Every step has a filesystem-safe `name` and exactly one action:

```yaml
version: 1
name: example-install
fixtures_dir: templates/example
defaults:
  detect_timeout: 90
  detect_interval: 2
  optional_timeout: 0
  template_threshold: 0.78
  scales: "0.75:1.35:0.05"
  min_confidence: 25
  min_similarity: 0.82
  key_delay: 0.12
steps:
  - name: welcome
    tap_text:
      text: Install
      roi: "rel:0.60,0.70,0.40,0.30"
    checkpoint:
      template: partition-page.png
      timeout: 60

  - name: optional-warning
    optional: true
    tap_template:
      template: warning-ok.png
      timeout: 5
    checkpoint: {text: Partitioning, timeout: 20}

  - name: product-key
    type: "${PRODUCT_KEY}"
  - name: advance
    key: [tab, ret]
  - name: wait-install
    wait_template: installed.png
  - name: quiet-frame
    settle:
      timeout: 30
      expected_region: "rel:0.15,0.80,0.70,0.10"
  - name: proof
    screenshot: installed-desktop
```

Supported actions:

| Action | Value | Effect |
|---|---|---|
| `tap_text` | text string or mapping | Wait for OCR text and tap its centre. |
| `tap_template` | fixture name(s) or mapping | Wait for the best template and tap its centre. `at: [x,y]` can retain a proven fixed control coordinate after the template positively identifies the state. |
| `type` | string | Type printable ASCII through QEMU qcodes. `${VAR}` references are expanded only in memory. |
| `key` | qcode/combo or list | Send one or more QEMU `sendkey` values such as `tab`, `ret`, or `ctrl-alt-f2`. |
| `wait_text` / `wait_template` | string or mapping | Wait without injecting input. |
| `settle` | mapping or `true` | Require successive steady framebuffer frames; accepts the existing settle thresholds and `rel:` expected region. |
| `sleep` | seconds | A deliberate delay for cases with no observable intermediate state. |
| `screenshot` | label | Save a labelled PNG. |

Text mappings accept `text`, `roi`, `timeout`, `interval`, `min_confidence`, and
`min_similarity`. Template mappings accept `template` (one filename or a
list), `roi`, `timeout`, `interval`, `threshold`, `scales`, and for taps `at`.
ROIs accept `x,y,width,height` or resolution-independent
`rel:x,y,width,height` fractions.

`optional: true` is valid on tap/wait actions. The runner probes for up to the
step timeout (zero by default), acts only on a match, and otherwise records the
step as `skipped`. It does not turn a failed checkpoint into a skip.

A `checkpoint` is a post-action screenshot plus exactly one `text` or
`template` assertion. It accepts the same detector thresholds, ROI, timeout,
and interval. If any action or assertion fails, the command exits nonzero,
names the failing step in `run.json`, and saves `NN-step-FAILED.png` from the
real framebuffer. Elapsed time by itself never counts as success.

## Mapping the Android shell table to YAML

The historical `android-x86.sh` table passes
`name/text/template/checkpoint/roi/expected-region` to `vision_step`. The YAML
equivalents are:

| Android table field | YAML |
|---|---|
| `name` | step `name` |
| OCR `text` | `tap_text.text` |
| fallback crop | an optional `tap_text`, then an optional `tap_template`, followed by a required wait/checkpoint for the next state |
| pre-click `savevm` checkpoint | post-action framebuffer `checkpoint` assertion; VM snapshots remain builder policy |
| detector ROI | `tap_text.roi` / `tap_template.roi` |
| expected-change region | explicit following `settle.expected_region` |
| fixed delay | `sleep`, only when no framebuffer state can express it |

For example, `welcome START start.png cp-preclick-welcome` becomes optional
`tap_text: {text: START}` and `tap_template: start.png` steps followed by a
required `wait_template` for the next visible state. This preserves OCR-first,
template-fallback behavior without double-tapping. Optional Android warning
rows need only one `optional: true` detector step.

## Authoring templates with `capture`

Boot a disposable clone to the desired state, then harvest a crop directly
into the flow's `fixtures_dir`:

```bash
ssh -X lab
scripts/install-vision/install-vision capture license-accepted \
  --flow scripts/install-vision/example.flow.yaml \
  --qmp /data/vms/soltest/example-author/qmp.sock \
  --work-dir /data/vms/soltest/example-author/captures
```

Drag a rectangle over a stable, distinctive region and press Enter. Escape
cancels. The source framebuffer is retained next to the capture evidence and
the crop is saved as `fixtures_dir/license-accepted.png`. Existing fixtures
are protected unless `--replace` is supplied. On a headless session, inspect
the retained framebuffer and pass `--region x,y,width,height`; the helper still
does the crop and validation without an image editor.

Before relying on a crop, exercise it against several captures and at any
supported resolution with `find_template.py`. Prefer a compact stable label or
control, exclude clocks/cursors/progress animation, and use an ROI when the
same motif occurs more than once.

The lower-level detector and one-step driver remain available for diagnostics:

```bash
scripts/install-vision/.venv/bin/python scripts/install-vision/find_text.py screen.png "SET UP OFFLINE"
scripts/install-vision/.venv/bin/python scripts/install-vision/find_template.py screen.png templates/example/next.png
scripts/install-vision/.venv/bin/python scripts/install-vision/driver.py step \
  --qmp /data/vms/soltest/example-author/qmp.sock \
  --work-dir /data/vms/soltest/example-author/one-step \
  welcome --text START --template templates/example/start.png
```
