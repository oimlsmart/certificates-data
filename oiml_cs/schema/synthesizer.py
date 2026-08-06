"""SchemaSynthesizer: aggregates ParsedCertificate list into a Schema.

This is the canonical schema builder. All denominators are correct (per
cert, not per-row). No `<value>` aggregates, no `[]` duplicates.
"""
from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from typing import Any

from oiml_cs.parsing.parsed_certificate import ParsedCertificate
from oiml_cs.schema.schema import Field, Schema, Section


class SchemaSynthesizer:
    """Synthesize a Schema from a list of ParsedCertificate instances."""

    def synthesize(
        self,
        parsed_certs: list[ParsedCertificate],
        recommendation: str,
        edition: int | None,
    ) -> Schema:
        sample_size = len(parsed_certs)
        schema = Schema(
            recommendation=recommendation,
            edition=edition,
            sample_size=sample_size,
            sample_size_note="too small for statistical schema" if sample_size < 5 else None,
        )

        # Each top-level section gets its own analysis.
        # Maps schema-section-name → ParsedCertificate attribute name.
        sections_to_analyze = [
            ("certificate", "header"),
            ("issuing_authority", "issuing_authority"),
            ("instrument", "instrument"),
            ("recommendation", "recommendation"),
            ("characteristics", "characteristics"),
        ]
        for section_name, attr_name in sections_to_analyze:
            section = self._analyze_section(parsed_certs, attr_name, section_name)
            if section.fields:
                schema.sections[section_name] = section

        # List-of-object sections: include (items) group
        for section_name in ("applicants", "manufacturers", "test_reports", "revision_history"):
            items_section = self._analyze_list_section(parsed_certs, section_name, sample_size)
            if items_section.fields:
                schema.sections[section_name] = items_section

        return schema

    def _analyze_section(
        self, parsed_certs: list[ParsedCertificate], attr_name: str, section_name: str
    ) -> Section:
        """Analyze a flat dict section: each key becomes a Field."""
        records: list[dict] = [getattr(p, attr_name) for p in parsed_certs]
        section = Section(name=section_name)
        all_keys: set[str] = set()
        for r in records:
            if isinstance(r, dict):
                all_keys.update(r.keys())

        for key in sorted(all_keys):
            values = [r.get(key) if isinstance(r, dict) else None for r in records]
            section.fields[key] = self._analyze_field(key, values)
        return section

    def _analyze_list_section(self, parsed_certs: list[ParsedCertificate], section_name: str, sample_size: int) -> Section:
        """Analyze a list-of-objects section (e.g. applicants).

        Produces:
          - '(present)':  Field describing the list presence
          - '(item).X':   Field for each key X present in any item
        """
        section = Section(name=section_name)
        lists = [getattr(p, section_name) for p in parsed_certs]
        # Presence field
        present_count = sum(1 for lst in lists if lst)
        section.fields["(present)"] = Field(
            name="(present)",
            type=f"list<object> ({sum(len(l) for l in lists)} items total)",
            present_count=present_count,
            total_count=sample_size,
        )
        # Per-item fields: gather all keys across all items
        item_keys: set[str] = set()
        for lst in lists:
            for item in lst:
                if isinstance(item, dict):
                    item_keys.update(item.keys())
        for key in sorted(item_keys):
            # For each cert, gather all values of this key across its items
            values: list[Any] = []
            for lst in lists:
                if not lst:
                    values.append(None)
                    continue
                vals = [item.get(key) for item in lst if isinstance(item, dict) and key in item]
                values.append(vals if vals else None)
            section.fields[f"(item).{key}"] = self._analyze_field(f"(item).{key}", values)
        return section

    def _analyze_field(self, name: str, values: list) -> Field:
        present = [v for v in values if v not in (None, "", [], {})]
        types = Counter(self._classify(v) for v in present)
        type_str = types.most_common(1)[0][0] if types else "unknown"

        distinct_count: int | None = None
        enum: list | None = None

        if type_str in ("string", "string(int-like)", "int", "bool"):
            sc = [v for v in present if not isinstance(v, (list, dict))]
            distinct = Counter(sc)
            if 1 < len(distinct) <= 25:
                distinct_count = len(distinct)
                enum = [
                    {"value": k, "count": cnt, "freq": round(cnt / len(present), 3) if present else 0}
                    for k, cnt in distinct.most_common(15)
                ]
        elif type_str.startswith("list<"):
            flat: list = []
            for v in present:
                if isinstance(v, list):
                    flat.extend(v)
            hashable = [
                json.dumps(x, sort_keys=True, default=str) if isinstance(x, (dict, list)) else x
                for x in flat
            ]
            distinct = Counter(hashable)
            if 1 < len(distinct) <= 25:
                distinct_count = len(distinct)
                enum = [{"value": k, "count": cnt} for k, cnt in distinct.most_common(15)]

        # Examples
        examples: list = []
        seen: set = set()
        for v in present:
            key = json.dumps(v, sort_keys=True, default=str) if not isinstance(v, str) else v
            if key in seen:
                continue
            seen.add(key)
            examples.append(v)
            if len(examples) >= 2:
                break

        return Field(
            name=name,
            type=type_str,
            present_count=len(present),
            total_count=len(values),
            distinct_count=distinct_count,
            enum=enum,
            examples=examples,
        )

    @staticmethod
    def _classify(v) -> str:
        if v is None:
            return "null"
        if isinstance(v, bool):
            return "bool"
        if isinstance(v, int):
            return "int"
        if isinstance(v, float):
            return "float"
        if isinstance(v, list):
            if not v:
                return "list?"
            inner = {SchemaSynthesizer._classify(x) for x in v}
            if len(inner) == 1:
                return f"list<{next(iter(inner))}>"
            return f"list<mixed:{','.join(sorted(inner))}>"
        if isinstance(v, dict):
            return "object"
        if isinstance(v, str):
            if re.fullmatch(r"-?\d+", v.strip()):
                return "string(int-like)"
            if re.fullmatch(r"-?\d+\.\d+", v.strip()):
                return "string(float-like)"
            return "string"
        return "unknown"
