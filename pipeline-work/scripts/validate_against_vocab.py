#!/usr/bin/env python3
"""Validate all cert YAMLs against their per-R vocabulary.

For each cert:
  1. Look up its R-number's vocabulary (schema/vocabularies/R<NN>.yaml).
  2. For each declared characteristic with an enum, check the cert's value(s)
     against the allowed set.
  3. Report violations: out-of-enum values, missing R-vocab, etc.

Outputs a per-R summary + a list of every violation for review.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402


def load_vocab(r_str: str) -> dict | None:
    path = ROOT / "schema" / "vocabularies" / f"{r_str}.yaml"
    if not path.exists():
        return None
    return yaml.safe_load(path.read_text())


def check_enum(values, allowed: list[str]) -> list[str]:
    """Return list of values not in allowed set."""
    if isinstance(values, str):
        values = [values]
    elif not isinstance(values, list):
        values = [str(values)]
    return [v for v in values if v not in allowed and v is not None]


def validate_cert(yaml_path: Path) -> list[dict]:
    """Return list of violations for one cert."""
    data = yaml.safe_load(yaml_path.read_text())
    r_str = yaml_path.parts[-3]
    vocab = load_vocab(r_str)
    if vocab is None:
        return [{"cert": yaml_path.stem, "R": r_str, "issue": "no_vocab_file"}]

    violations: list[dict] = []
    char_specs = vocab.get("characteristics") or {}
    chars = (data.get("characteristics") or {}).get("type_level") or {}

    for label, spec in char_specs.items():
        if not spec or spec.get("type") not in ("enum", "enum_multi"):
            continue
        allowed = spec.get("values") or []
        if not allowed:
            continue
        if label not in chars:
            continue
        value_obj = chars[label]
        if not isinstance(value_obj, dict):
            continue
        value = value_obj.get("value")
        if value is None:
            continue
        bad = check_enum(value, allowed)
        if bad:
            violations.append({
                "cert": yaml_path.stem,
                "R": r_str,
                "label": label,
                "bad_values": bad,
                "allowed": allowed,
            })
    return violations


def main() -> int:
    yaml_root = ROOT / "yaml"
    all_violations: list[dict] = []
    per_r = defaultdict(lambda: {"total": 0, "violations": 0, "samples": []})

    for yp in sorted(yaml_root.glob("R*/*/*.yaml")):
        r_str = yp.parts[-3]
        per_r[r_str]["total"] += 1
        vs = validate_cert(yp)
        if vs:
            per_r[r_str]["violations"] += len(vs)
            all_violations.extend(vs)
            per_r[r_str]["samples"].extend(vs[:2])

    print(f"\n=== PER-R SUMMARY ===")
    print(f"{'R':6s} {'certs':>6s} {'violations':>11s}")
    for r in sorted(per_r.keys(), key=lambda k: int(k[1:])):
        v = per_r[r]
        flag = "✓" if v["violations"] == 0 else "✗"
        print(f"  {flag} {r:4s} {v['total']:>6d} {v['violations']:>11d}")

    print(f"\n=== SAMPLE VIOLATIONS (first 30) ===")
    for v in all_violations[:30]:
        print(f"  [{v['R']}] {v['cert']}")
        if "issue" in v:
            print(f"      issue: {v['issue']}")
        else:
            print(f"      {v['label']}: {v['bad_values']} not in {v['allowed']}")

    print(f"\nTotal violations: {len(all_violations)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
