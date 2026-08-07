#!/usr/bin/env python3
"""One-off: merge certificates/R0XX/ folders into certificates/RXX/.

Idempotent: skips folders that don't exist or are already empty.
"""
import json
import os
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CERTS = ROOT / "certificates"
MANIFEST = ROOT / "manifest.jsonl"

R_RE = re.compile(r"^R0(\d+)$")


def canonical(name: str) -> str | None:
    m = R_RE.match(name)
    return f"R{m.group(1)}" if m else None


def main() -> int:
    moved = 0
    folders_removed = 0
    for src in sorted(CERTS.iterdir()):
        if not src.is_dir():
            continue
        dst_name = canonical(src.name)
        if not dst_name or dst_name == src.name:
            continue
        dst = CERTS / dst_name
        dst.mkdir(parents=True, exist_ok=True)
        for f in src.iterdir():
            target = dst / f.name
            if target.exists():
                src_size = f.stat().st_size
                dst_size = target.stat().st_size
                if src_size == dst_size:
                    f.unlink()
                    continue
                raise SystemExit(f"REAL COLLISION (different bytes): {f} -> {target}")
            shutil.move(str(f), str(target))
            moved += 1
        remaining = list(src.iterdir())
        if remaining:
            raise SystemExit(f"Source not empty after move: {src} -> {remaining}")
        src.rmdir()
        folders_removed += 1
        print(f"  {src.name}/ -> {dst_name}/  (merged, removed source)")

    print(f"\nMoved {moved} files, removed {folders_removed} source folders")

    rows = [json.loads(l) for l in MANIFEST.open()]
    rewritten = 0
    with MANIFEST.open("w", encoding="utf-8") as f:
        for r in rows:
            p = r.get("local_path")
            if p:
                parts = p.split("/", 2)
                if len(parts) >= 2:
                    c = canonical(parts[1])
                    if c and c != parts[1]:
                        parts[1] = c
                        r["local_path"] = "/".join(parts)
                        rewritten += 1
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"Rewrote {rewritten} manifest paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
