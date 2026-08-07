#!/usr/bin/env python3
"""Migrate all cert YAMLs to the canonical shared-core model.

For each cert YAML:
  1. Load it.
  2. Apply LabelCanonicalizer to every characteristic label (type_level,
     model_level[].attribute, config_level[].attribute, components[].characteristics).
  3. Re-emit with the canonical labels.
  4. Preserve everything else verbatim.

Idempotent: running twice produces the same output. The original (pre-canonical)
labels are preserved under `_raw_labels` for traceability.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402

from oiml_cs.units.canonicalizer import LabelCanonicalizer  # noqa: E402
from oiml_cs.values import normalize_accuracy_class  # noqa: E402


def _normalize_value_object(value_obj: dict, normalizer) -> tuple[dict, bool]:
    """Apply a normalizer to a {value, unit_symbol, ...} dict.

    Returns (new_dict, changed). If normalizer returns [], the whole value
    object is set to value=null (filtered as junk).
    """
    if not isinstance(value_obj, dict):
        return value_obj, False
    raw = value_obj.get("value")
    normalized = normalizer(raw)
    if isinstance(normalized, list):
        if not normalized:
            # Junk filtered — nullify
            new = dict(value_obj)
            new["value"] = None
            new["_normalized"] = "filtered-junk"
            return new, True
        if len(normalized) == 1:
            new = dict(value_obj)
            new["value"] = normalized[0]
            new["_normalized_from"] = raw
            return new, True
        # Multi-value: preserve as list
        new = dict(value_obj)
        new["value"] = normalized
        new["_normalized_from"] = raw
        return new, True
    return value_obj, False


def migrate_one(data: dict, canonicalizer: LabelCanonicalizer) -> tuple[dict, dict]:
    """Migrate a single cert's parsed dict. Returns (new_dict, stats).

    Stats: {labels_renamed, accuracy_normalized, raw_labels_kept}
    """
    stats = {"labels_renamed": 0, "accuracy_normalized": 0, "raw_labels_kept": []}

    def _canon(label: str) -> str:
        new = canonicalizer.canonical_for(label)
        if new != label:
            stats["labels_renamed"] += 1
        else:
            stats["raw_labels_kept"].append(label)
        return new

    chars = data.get("characteristics") or {}

    # type_level: dict of label -> {value, unit_symbol, ...}
    new_type_level: dict = {}
    raw_labels_for_type_level: dict[str, str] = {}
    for label, value_obj in (chars.get("type_level") or {}).items():
        canonical = _canon(label)
        # Apply accuracy_class normalizer
        if canonical == "accuracy_class" and isinstance(value_obj, dict):
            value_obj, changed = _normalize_value_object(value_obj, normalize_accuracy_class)
            if changed:
                stats["accuracy_normalized"] += 1
        if canonical in new_type_level:
            existing_raw = new_type_level[canonical].get("_raw_label")
            if existing_raw:
                new_type_level[existing_raw] = new_type_level.pop(canonical)
                raw_labels_for_type_level[existing_raw] = existing_raw
            new_type_level[label] = value_obj
            raw_labels_for_type_level[label] = label
        else:
            new_type_level[canonical] = value_obj
            if canonical != label:
                raw_labels_for_type_level[canonical] = label
    chars["type_level"] = new_type_level
    if raw_labels_for_type_level:
        data.setdefault("_traceability", {})["raw_labels"] = raw_labels_for_type_level

    # model_level: list of {attribute, unit_symbol, values[]}
    for entry in chars.get("model_level") or []:
        entry["attribute"] = _canon(entry.get("attribute", ""))
        if entry["attribute"] == "accuracy_class":
            for v in entry.get("values") or []:
                if isinstance(v, dict) and "value" in v:
                    normalized = normalize_accuracy_class(v["value"])
                    if normalized:
                        v["value"] = normalized[0] if len(normalized) == 1 else normalized
                        stats["accuracy_normalized"] += 1

    # config_level: list of {attribute, axis, values[]}
    for entry in chars.get("config_level") or []:
        entry["attribute"] = _canon(entry.get("attribute", ""))

    # components: list of {role, type_designations, alternatives, characteristics}
    for comp in data.get("components") or []:
        comp_chars = comp.get("characteristics")
        if not isinstance(comp_chars, dict):
            continue
        new_comp_chars: dict = {}
        for label, value in comp_chars.items():
            new_comp_chars[_canon(label)] = value
        comp["characteristics"] = new_comp_chars

    data["characteristics"] = chars
    return data, stats


def main() -> int:
    canonicalizer = LabelCanonicalizer()
    yaml_root = ROOT / "yaml"
    total_renamed = 0
    total_acc_normalized = 0
    total_files = 0
    per_r: dict[str, dict] = defaultdict(lambda: {"labels": 0, "accuracy": 0})

    for yp in sorted(yaml_root.glob("R*/*/*.yaml")):
        r_str = yp.parts[-3]
        data = yaml.safe_load(yp.read_text())
        if not isinstance(data, dict):
            continue
        migrated, stats = migrate_one(data, canonicalizer)
        yp.write_text(
            yaml.safe_dump(migrated, allow_unicode=True, sort_keys=False,
                           default_flow_style=False, width=100),
            encoding="utf-8",
        )
        total_files += 1
        total_renamed += stats["labels_renamed"]
        total_acc_normalized += stats["accuracy_normalized"]
        per_r[r_str]["labels"] += stats["labels_renamed"]
        per_r[r_str]["accuracy"] += stats["accuracy_normalized"]

    print(f"Migrated {total_files} cert YAMLs")
    print(f"Total labels canonicalized: {total_renamed}")
    print(f"Total accuracy_class values normalized: {total_acc_normalized}")
    print("\nPer-R:")
    print(f"  {'R':6s} {'labels':>8s} {'accuracy':>10s}")
    for r in sorted(per_r.keys(), key=lambda k: -(per_r[k]["labels"] + per_r[k]["accuracy"])):
        v = per_r[r]
        print(f"  {r:6s} {v['labels']:>8d} {v['accuracy']:>10d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
