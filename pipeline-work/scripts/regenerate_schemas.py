#!/usr/bin/env python3
"""Regenerate per-R schemas from cached YAMLs.

Use this when the unitsdb alias map or synthesizer logic changes and you
want to refresh schemas without re-calling the GLM extract API.
"""
from __future__ import annotations

import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402

from oiml_cs.domain.value_objects import RNumber  # noqa: E402
from oiml_cs.extraction.parsed_certificate import ParsedCertificate  # noqa: E402
from oiml_cs.units import UnitsDb  # noqa: E402


def load_yaml(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def parsed_from_yaml(d: dict) -> ParsedCertificate:
    """Reverse of CertificateYamlSerializer — read YAML back into ParsedCertificate."""
    p = ParsedCertificate()
    p.certificate = d.get("certificate", {}) or {}
    p.issuing_authority = d.get("issuing_authority", {}) or {}
    p.applicants = d.get("applicants", []) or []
    p.manufacturers = d.get("manufacturers", []) or []
    p.certified_type = d.get("certified_type", {}) or {}
    p.model_family = d.get("model_family")
    chars = d.get("characteristics", {}) or {}
    for k, v in (chars.get("type_level") or {}).items():
        if isinstance(v, dict):
            from oiml_cs.extraction.parsed_certificate import CharacteristicValue
            p.characteristics_type_level[k] = CharacteristicValue(
                value=v.get("value"),
                unit_symbol=v.get("unit_symbol"),
                unit_id=v.get("unit_id"),
                footnote_markers=v.get("footnote_markers", []) or [],
            )
    from oiml_cs.extraction.parsed_certificate import (
        Component, ConfigLevelEntry, ModelLevelEntry, MatrixTable,
        RevisionEntry, TestReport, Footnote,
    )
    p.characteristics_model_level = [
        ModelLevelEntry(attribute=e.get("attribute", ""),
                        unit=e.get("unit") or e.get("unit_symbol"),
                        values=e.get("values", []) or [])
        for e in chars.get("model_level", []) or []
    ]
    p.characteristics_config_level = [
        ConfigLevelEntry(attribute=e.get("attribute", ""),
                        axis=e.get("axis", ""),
                        values=e.get("values", []) or [])
        for e in chars.get("config_level", []) or []
    ]
    p.matrix_tables = [
        MatrixTable(name=t.get("name", ""), columns=t.get("columns", []) or [],
                    rows=t.get("rows", []) or [], description=t.get("description"),
                    footnotes=t.get("footnotes", []) or [])
        for t in d.get("matrix_tables", []) or []
    ]
    p.components = [
        Component(role=c.get("role", ""),
                  type_designations=c.get("type_designations", []) or [],
                  alternatives=c.get("alternatives"),
                  characteristics=c.get("characteristics", {}) or {})
        for c in d.get("components", []) or []
    ]
    p.recommendation = d.get("recommendation", {}) or {}
    p.test_reports = [TestReport(**t) for t in d.get("test_reports", []) or []]
    p.revision_history = [RevisionEntry(**r) for r in d.get("revision_history", []) or []]
    p.footnotes = [Footnote(**f) for f in d.get("footnotes", []) or []]
    return p


def write_schema_for_r(r_str: str, parsed_certs: list[ParsedCertificate], output_root: Path) -> Path:
    """Same logic as ProcessRecommendation._write_summary_schema but standalone."""
    units_db = UnitsDb()
    type_level: dict[str, dict[str | None, list]] = defaultdict(lambda: defaultdict(list))
    model_level_attrs: Counter = Counter()
    config_level_attrs: Counter = Counter()
    matrix_table_names: Counter = Counter()

    for p in parsed_certs:
        for label, cv in p.characteristics_type_level.items():
            if cv.value is None:
                continue
            unit_sym = cv.unit_symbol
            unit_id = cv.unit_id
            if unit_sym and not unit_id:
                entry = units_db.unit_for_symbol(unit_sym)
                if entry:
                    unit_id = entry.unit_id
            type_level[label][unit_sym or None].append({"value": cv.value, "unit_id": unit_id})
        for entry in p.characteristics_model_level:
            model_level_attrs[entry.attribute] += 1
        for entry in p.characteristics_config_level:
            config_level_attrs[entry.attribute] += 1
        for mt in p.matrix_tables:
            matrix_table_names[mt.name] += 1

    n = len(parsed_certs)
    type_level_section: dict[str, dict] = {}
    for attr, by_unit in type_level.items():
        total_count = sum(len(vs) for vs in by_unit.values())
        if total_count == 0:
            continue
        attr_entry: dict = {"fill_rate": round(total_count / n, 3) if n else 0,
                            "present_count": total_count}
        if len(by_unit) == 1:
            only_unit = next(iter(by_unit.keys()))
            only_values = next(iter(by_unit.values()))
            unit_id = only_values[0].get("unit_id") if only_values else None
            attr_entry["unit_symbol"] = only_unit
            if unit_id:
                attr_entry["unit_id"] = unit_id
            attr_entry["top_values"] = top_numeric_values(only_values)
        else:
            attr_entry["by_unit"] = {}
            for unit_sym, values in sorted(by_unit.items(), key=lambda kv: -len(kv[1])):
                unit_id = values[0].get("unit_id") if values else None
                sub = {"count": len(values), "top_values": top_numeric_values(values)}
                if unit_id:
                    sub["unit_id"] = unit_id
                attr_entry["by_unit"][unit_sym or "null"] = sub
        type_level_section[attr] = attr_entry

    schema = {
        "recommendation": r_str,
        "sample_size": n,
        "summary": {
            "certs_with_model_family": sum(1 for p in parsed_certs if p.model_family),
            "certs_with_components": sum(1 for p in parsed_certs if p.components),
            "certs_with_matrix_tables": sum(1 for p in parsed_certs if p.matrix_tables),
            "certs_with_footnotes": sum(1 for p in parsed_certs if p.footnotes),
            "total_model_variants": sum(
                len((p.model_family or {}).get("models") or [])
                for p in parsed_certs if p.model_family
            ),
            "total_matrix_tables": sum(len(p.matrix_tables) for p in parsed_certs),
        },
        "type_level_characteristics": type_level_section,
        "model_level_attributes": dict(model_level_attrs.most_common()),
        "config_level_attributes": dict(config_level_attrs.most_common()),
        "matrix_table_names": dict(matrix_table_names.most_common()),
    }
    schema_path = output_root / "schema" / f"{r_str}.yaml"
    schema_path.write_text(
        yaml.safe_dump(schema, allow_unicode=True, sort_keys=False, default_flow_style=False, width=100),
        encoding="utf-8",
    )
    return schema_path


def top_numeric_values(values: list[dict], limit: int = 10) -> list[dict]:
    scalar_counts: Counter = Counter()
    range_counts: Counter = Counter()
    string_counts: Counter = Counter()
    for v in values:
        val = v.get("value")
        if isinstance(val, dict) and ("min" in val or "max" in val):
            range_counts[f"min={val.get('min')}, max={val.get('max')}"] += 1
        elif isinstance(val, (int, float)) and not isinstance(val, bool):
            scalar_counts[val] += 1
        elif isinstance(val, str):
            string_counts[val] += 1
        else:
            string_counts[str(val)] += 1
    out: list[dict] = []
    for val, count in scalar_counts.most_common(limit):
        out.append({"value": val, "count": count})
    for spec, count in range_counts.most_common(limit):
        out.append({"range": spec, "count": count})
    for s, count in string_counts.most_common(limit):
        out.append({"value": s, "count": count})
    return out[:limit]


def main() -> int:
    yaml_root = ROOT / "yaml"
    by_r: dict[str, list[ParsedCertificate]] = defaultdict(list)
    for yp in sorted(yaml_root.glob("R*/*/*.yaml")):
        r_str = yp.parts[-3]  # yaml/R60/2021/cert.yaml → "R60"
        by_r[r_str].append(parsed_from_yaml(load_yaml(yp)))

    print(f"Regenerating {len(by_r)} schemas...")
    for r_str, parsed in sorted(by_r.items()):
        path = write_schema_for_r(r_str, parsed, ROOT)
        print(f"  {r_str}: {len(parsed)} certs → {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
