"""Content-addressed object store, and the guard that keeps stage 4 off the fleet.

Objects are immutable and named by their own sha256, so materializing a release
is hardlinking, and two releases sharing a member share the inode. A "release"
is therefore a few KB of directory entries, which is what makes keeping the last
N closures per station free — and free rollback is the entire point of §4.

THE LIVE-ROOT GUARD. Stage 4 produces the MECHANISM; running it against the
fleet is a separate authorisation. That is enforced here rather than remembered,
because "I will be careful" is exactly the property that fails at 3am: any root
under the live streamhost tree is refused outright. There is no override flag on
purpose — a flag would be found and used, and the person who finds it will not
be the person who read this paragraph.
"""

from __future__ import annotations

import hashlib
import os
import shutil
from pathlib import Path

from .denylist import refuse_if_protected

LIVE_ROOTS = ("/data/vms/streamhost",)


class LiveRootRefused(RuntimeError):
    """Raised when asked to write anywhere under the live serving tree."""


def refuse_live_root(root: Path) -> None:
    resolved = str(Path(root).resolve())
    for live in LIVE_ROOTS:
        if resolved == live or resolved.startswith(live.rstrip("/") + "/"):
            raise LiveRootRefused(
                f"refusing to operate on {resolved!r}: it is under the LIVE serving tree. "
                "Stage 4 builds the transactional apply mechanism; running it against the fleet "
                "is a separate authorisation, and there is deliberately no flag to override this. "
                "Point --root at a sandbox."
            )


class ObjectStore:
    def __init__(self, root: Path):
        refuse_live_root(root)
        self.root = Path(root)
        self.objects = self.root / "objects" / "sha256"

    def add_bytes(self, data: bytes) -> str:
        """Store `data`, return its hash. Idempotent by construction."""
        digest = hashlib.sha256(data).hexdigest()
        path = self.objects / digest[:2] / digest
        if path.exists():
            return digest
        path.parent.mkdir(parents=True, exist_ok=True)
        # tmp + rename: a reader must never see a half-written object, and two
        # writers racing on the same content must not corrupt it.
        tmp = path.with_suffix(f".tmp.{os.getpid()}")
        tmp.write_bytes(data)
        os.replace(tmp, path)
        return digest

    def path_of(self, digest: str) -> Path:
        return self.objects / digest[:2] / digest

    def has(self, digest: str) -> bool:
        return self.path_of(digest).exists()

    def verify(self, digest: str) -> bool:
        """Re-hash an object. A store that cannot detect its own corruption is
        a store that will one day materialize corruption confidently."""
        path = self.path_of(digest)
        if not path.exists():
            return False
        return hashlib.sha256(path.read_bytes()).hexdigest() == digest

    def materialize(self, digest: str, dest: Path) -> None:
        """Hardlink an object into a release. Falls back to copy across devices."""
        refuse_if_protected(str(dest), "materialized release member")
        dest.parent.mkdir(parents=True, exist_ok=True)
        src = self.path_of(digest)
        if dest.exists() or dest.is_symlink():
            dest.unlink()
        try:
            os.link(src, dest)
        except OSError:
            shutil.copy2(src, dest)

    def reachable(self, release_dirs: list[Path]) -> set[str]:
        """Every object named by any release's closure.json."""
        import json

        live: set[str] = set()
        for release in release_dirs:
            manifest = release / "closure.json"
            if not manifest.exists():
                continue
            try:
                data = json.loads(manifest.read_text())
            except ValueError:
                # An unreadable manifest means UNKNOWN reachability, not zero.
                # GC must fail toward disk pressure, never toward data loss.
                raise
            live.update(data.get("members", {}).values())
        return live

    def gc(self, release_dirs: list[Path], dry_run: bool = True) -> list[str]:
        """Refuse-by-default sweep: only objects no release names.

        Returns what would be (or was) removed. GC bugs must fail toward disk
        pressure, not data loss, so anything it cannot account for is KEPT.
        """
        keep = self.reachable(release_dirs)
        removed = []
        if not self.objects.exists():
            return removed
        for shard in sorted(self.objects.iterdir()):
            if not shard.is_dir():
                continue
            for obj in sorted(shard.iterdir()):
                if obj.name in keep or obj.suffix.startswith(".tmp"):
                    continue
                removed.append(obj.name)
                if not dry_run:
                    obj.unlink()
        return removed
