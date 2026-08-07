#!/usr/bin/env python3
"""One-off: split each certificates/R<NN>/ folder into R<NN>/<edition>/.

Edition year is the 4-digit segment after the R-number in the cert `num`
(e.g. R60/2000-NL1-2004-09 -> edition 2000).

Idempotent: certs already under their edition subfolder are skipped.
"""
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CERTS = ROOT / "certificates"
MANIFEST = ROOT / "manifest.jsonl"

NUM_RE = re.compile(r"^R0*(\d+)/(\d{4})-", re.IGNORECASE)


def edition_subpath(num: str) -> str | None:
    m = NUM_RE.match(num or "")
    if not m:
        return None
    return f"R{m.group(1)}/{m.group(2)}"


def main() -> int:
    rows = [json.loads(l) for l in MANIFEST.open()]

    moved = 0
    skipped_already = 0
    no_path = 0
    unparseable = 0

    with MANIFEST.open("w", encoding="utf-8") as fout:
        for r in rows:
            old = r.get("local_path")
            if not old:
                no_path += 1
                fout.write(json.dumps(r, ensure_ascii=False) + "\n")
                continue
            sub = edition_subpath(r.get("num", ""))
            if not sub:
                unparseable += 1
                fout.write(json.dumps(r, ensure_ascii=False) + "\n")
                continue
            fname = Path(old).name
            new_rel = f"certificates/{sub}/{fname}"
            if new_rel == old:
                skipped_already += 1
                fout.write(json.dumps(r, ensure_ascii=False) + "\n")
                continue
            src = ROOT / old
            dst = ROOT / new_rel
            if not src.exists():
                fout.write(json.dumps(r, ensure_ascii=False) + "\n")
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            if dst.exists():
                if dst.stat().st_size == src.stat().st_size:
                    src.unlink()
                else:
                    raise SystemExit(f"REAL COLLISION: {src} -> {dst}")
            else:
                shutil.move(str(src), str(dst))
                moved += 1
            r["local_path"] = new_rel
            fout.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"Moved: {moved}")
    print(f"Already in place: {skipped_already}")
    print(f"No local_path: {no_path}")
    print(f"Unparseable num: {unparseable}")

    for d in sorted(CERTS.iterdir()):
        if not d.is_dir() or not d.name.startswith("R"):
            continue
        leftover = [p for p in d.iterdir() if p.is_file()]
        if leftover:
            print(f"WARN: {len(leftover)} loose files left in {d.name}/")
            for p in leftover[:3]:
                print(f"  {p.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
