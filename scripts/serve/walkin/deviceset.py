"""The hard constraint, in code: a clone's command line may differ from its
station's in paths, ports, tap names and netdev options — **and in nothing else**.

`docs/lab/OPERATING-RULES.md` rule 6: checkpoint + binary + device set are ONE
combination. A pool member boots with `-loadvm golden`, so a device added,
removed or retyped does not degrade gracefully — the restore fails, or worse,
succeeds against a machine the vmstate does not describe. The ledger states the
constraint (§5.2); this module is the thing that actually refuses.

The check is a comparison, not a whitelist of edits: whatever `derive.py` did,
the RESULT is put back beside the base command line and every difference must
fall in an allowed class. That way a future override key cannot quietly widen
what an override is permitted to do — it still has to pass through here.

Allowed, per flag:

| Flag        | Must match exactly            | May differ            |
|-------------|-------------------------------|-----------------------|
| `-device`   | driver + every option         | `mac=`                |
| `-drive`    | every option                  | `file=`               |
| `-netdev`   | `id=`                         | backend type, options |
| `-chardev`  | backend + `id=`               | `path=`/`host=`/`port=`|
| machine set | byte-identical                | —                     |
| bookkeeping | —                             | free (paths only)     |

`machine set` is `-machine -cpu -smp -m -accel -bios -vga -global -display
-audiodev -rtc -boot -serial -k -rom -object` — the flags that shape what the
guest sees. `bookkeeping` is `-name -pidfile -qmp -monitor -D`.

Only `-sandbox`, `-loadvm` and `-S` may be ADDED, and nothing may be removed:
the sandbox flags are host-side confinement (brief §6.2) and `-loadvm golden -S`
is what makes a pool member instant-ready and paused.
"""

from __future__ import annotations

DEVICE_FLAGS = ("-device", "-drive", "-netdev", "-chardev")
MACHINE_FLAGS = (
    "-machine", "-cpu", "-smp", "-m", "-accel", "-bios", "-vga", "-global",
    "-display", "-audiodev", "-rtc", "-boot", "-serial", "-k", "-rom", "-object",
)  # fmt: skip
BOOKKEEPING_FLAGS = ("-name", "-pidfile", "-qmp", "-monitor", "-D")
ADDABLE_FLAGS = ("-sandbox", "-loadvm", "-S")

# The one option per device flag an override is allowed to move.
_MUTABLE = {"-device": {"mac"}, "-drive": {"file"}, "-chardev": {"path", "host", "port"}}
# What identifies a chardev/netdev backend beyond its options.
_BACKEND_IDENTITY = {"-chardev": ("id",), "-netdev": ("id",)}


class DeviceSetError(ValueError):
    """An override that would change the device set. Never recoverable."""


def _pairs(argv: list) -> list:
    """argv -> [(flag, value|None)], in order. A bare flag carries None."""
    out = []
    i = 1
    while i < len(argv):
        tok = argv[i]
        if not tok.startswith("-"):
            raise DeviceSetError(f"stray positional argument {tok!r} in a qemu command line")
        if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
            out.append((tok, argv[i + 1]))
            i += 2
        else:
            out.append((tok, None))
            i += 1
    return out


def parse_opts(value: str) -> tuple:
    """`pcnet,netdev=n0,mac=…` -> ("pcnet", {"netdev": "n0", "mac": "…"})."""
    parts = (value or "").split(",")
    head = parts[0] if parts and "=" not in parts[0] else ""
    body = parts[1:] if head else parts
    opts = {}
    for part in body:
        if not part:
            continue
        key, _, val = part.partition("=")
        opts[key] = val
    return head, opts


def _compare_device(flag: str, base: str, derived: str) -> None:
    base_head, base_opts = parse_opts(base)
    new_head, new_opts = parse_opts(derived)
    for key in _BACKEND_IDENTITY.get(flag, ()):
        if base_opts.get(key) != new_opts.get(key):
            raise DeviceSetError(
                f"{flag}: {key}= changed {base_opts.get(key)!r} -> {new_opts.get(key)!r}; it is the device's identity"
            )
    if flag == "-netdev":
        # The backend (tap/user/none) and its options are HOST-side wiring. The
        # guest still sees the same `-device` bound to the same netdev id, which
        # is what the vmstate describes — so this is the one type an override may
        # legitimately change (ledger §5.2).
        return
    if base_head != new_head:
        raise DeviceSetError(
            f"{flag}: driver retyped {base_head!r} -> {new_head!r} — the golden was captured on {base_head!r}"
        )
    mutable = _MUTABLE.get(flag, set())
    added = sorted(set(new_opts) - set(base_opts) - mutable)
    removed = sorted(set(base_opts) - set(new_opts) - mutable)
    if added or removed:
        raise DeviceSetError(
            f"{flag} {base_head or base!r}: option(s) added {added} removed {removed}"
            " — an override may change paths, ports, tap names and netdev options only"
        )
    for key in sorted(set(base_opts) & set(new_opts)):
        if key in mutable:
            continue
        if base_opts[key] != new_opts[key]:
            raise DeviceSetError(
                f"{flag} {base_head or base!r}: {key}= changed "
                f"{base_opts[key]!r} -> {new_opts[key]!r}, which is part of the device set"
            )


def assert_same_device_set(base_argv: list, derived_argv: list, expect_binary: str = "") -> None:
    """Raise unless `derived_argv` is `base_argv` with only allowed changes.

    Called on EVERY spawn, not just when an override file changes: the check is
    cheap and the failure it prevents costs a golden.
    """
    # `expect_binary` is the station file's `overrides.binary` — the DECLARED
    # emulator for this golden, which may differ from the bare name the launcher
    # happens to resolve off PATH. Nothing else may move it.
    wanted = expect_binary or base_argv[0]
    if derived_argv[0] != wanted:
        raise DeviceSetError(
            f"emulator binary changed {wanted!r} -> {derived_argv[0]!r}; "
            "the golden is bound to the binary it was captured against (rule 6)"
        )
    base = _pairs(base_argv)
    derived = [p for p in _pairs(derived_argv) if p[0] not in ADDABLE_FLAGS]
    base_kept = [p for p in base if p[0] not in ADDABLE_FLAGS]

    base_flags = [f for f, _ in base_kept]
    new_flags = [f for f, _ in derived]
    if base_flags != new_flags:
        missing = sorted(set(base_flags) - set(new_flags))
        extra = sorted(set(new_flags) - set(base_flags))
        raise DeviceSetError(
            f"flag sequence changed (missing {missing}, added {extra}); an override may not add or remove a flag"
        )

    for (flag, base_val), (_, new_val) in zip(base_kept, derived):
        if flag in DEVICE_FLAGS:
            _compare_device(flag, base_val or "", new_val or "")
        elif flag in MACHINE_FLAGS:
            if base_val != new_val:
                raise DeviceSetError(f"{flag}: {base_val!r} -> {new_val!r}; this flag shapes what the guest sees")
        elif flag not in BOOKKEEPING_FLAGS:
            raise DeviceSetError(
                f"{flag}: unclassified flag — classify it in deviceset.py before letting a clone carry it"
            )


def signature(argv: list) -> tuple:
    """The device set as one comparable value, for logging and tests."""
    out = []
    for flag, value in _pairs(argv):
        if flag == "-netdev":
            # The backend is host-side wiring; only the id is part of the set.
            _, opts = parse_opts(value or "")
            out.append((flag, "", (("id", opts.get("id", "")),)))
        elif flag in DEVICE_FLAGS:
            head, opts = parse_opts(value or "")
            keep = {k: v for k, v in opts.items() if k not in _MUTABLE.get(flag, set())}
            out.append((flag, head, tuple(sorted(keep.items()))))
        elif flag in MACHINE_FLAGS:
            out.append((flag, value, ()))
    return tuple(out)
