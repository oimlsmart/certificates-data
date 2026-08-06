"""SchemaRenderer: render Schema as human-readable YAML or JSON stats."""
from __future__ import annotations

import json

from oiml_cs.schema.schema import Schema


class SchemaRenderer:
    def render_human(self, schema: Schema) -> str:
        lines: list[str] = []
        lines.append(f"# OIML {schema.recommendation} Certificate of Conformity — YAML Schema")
        lines.append("#")
        lines.append(f"# Synthesized from {schema.sample_size} certificate instances.")
        if schema.sample_size_note:
            lines.append(f"# NOTE: {schema.sample_size_note}")
        lines.append("#")
        lines.append("# Field fill_rate = fraction of instances where the field had a non-empty value.")
        lines.append("# enum values are listed only when 1 < distinct_count <= 25.")
        lines.append("")
        lines.append(f"recommendation: OIML {schema.recommendation}")
        if schema.edition:
            lines.append(f"edition: {schema.edition}")
        lines.append(f"sample_size: {schema.sample_size}")
        if schema.sample_size_note:
            lines.append(f"sample_size_note: {schema.sample_size_note!r}")
        lines.append("")
        lines.append("sections:")

        section_order = [
            "certificate", "issuing_authority", "applicants", "manufacturers",
            "instrument", "recommendation", "test_reports",
            "characteristics", "revision_history",
        ]
        ordered = [s for s in section_order if s in schema.sections]
        extras = [s for s in schema.sections if s not in section_order]
        for section_name in ordered + extras:
            section = schema.sections[section_name]
            lines.append(f"  {section_name}:")
            # sort by fill_rate desc, with "(present)" first
            sorted_fields = sorted(
                section.fields.items(),
                key=lambda kv: (
                    0 if kv[0] == "(present)" else 1,
                    -kv[1].fill_rate,
                ),
            )
            for fname, field in sorted_fields:
                lines.append(f"    {fname}:")
                lines.append(f"      type: {field.type}")
                lines.append(f"      fill_rate: {field.fill_rate}  # {field.present_count}/{field.total_count}")
                if field.distinct_count:
                    lines.append(f"      distinct_count: {field.distinct_count}")
                if field.enum:
                    lines.append("      enum:")
                    for e in field.enum[:15]:
                        if isinstance(e, dict) and "freq" in e:
                            lines.append(f"        - value: {e['value']!r}  (n={e['count']}, freq={e['freq']})")
                        else:
                            lines.append(f"        - {e!r}")
                for ex in field.examples[:2]:
                    lines.append(f"      example: {ex!r}")
        return "\n".join(lines) + "\n"

    def render_stats(self, schema: Schema) -> str:
        return json.dumps(
            {
                "recommendation": schema.recommendation,
                "edition": schema.edition,
                "sample_size": schema.sample_size,
                "sections": {
                    sname: {
                        fname: {
                            "type": f.type,
                            "fill_rate": f.fill_rate,
                            "present_count": f.present_count,
                            "total_count": f.total_count,
                            "distinct_count": f.distinct_count,
                            "enum": f.enum,
                            "examples": f.examples,
                        }
                        for fname, f in section.fields.items()
                    }
                    for sname, section in schema.sections.items()
                },
            },
            indent=2,
            default=str,
        )
