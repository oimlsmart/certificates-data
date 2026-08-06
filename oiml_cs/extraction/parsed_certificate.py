"""ParsedCertificate: layered value object (replaces parsing.ParsedCertificate).

Conforms to schema/_common_certificate_schema.yaml. Sections are explicitly
layered (type_level / model_level / config_level characteristics, optional
model_family and components, optional matrix_tables).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class CharacteristicValue:
    """A single characteristic value with the unit separated out.

    Value forms:
      - number (int/float)
      - {"min": num|null, "max": num|null} for ranges
      - string for formulas/symbols/enum-like values (e.g. "Emax/14000", "C3")
    """
    value: Any
    unit_symbol: str | None = None
    unit_id: str | None = None
    footnote_markers: list[str] = field(default_factory=list)


@dataclass
class ModelVariant:
    """One model variant in a model family."""
    model_id: str
    label: str | None = None
    attributes: dict[str, Any] = field(default_factory=dict)


@dataclass
class ModelLevelEntry:
    """One attribute varying across models."""
    attribute: str
    unit: str | None = None
    values: list[dict] = field(default_factory=list)  # {model, value, footnote_markers}


@dataclass
class ConfigLevelEntry:
    """One attribute varying across a configuration axis."""
    attribute: str
    axis: str
    values: list[dict] = field(default_factory=list)  # {condition, value}


@dataclass
class Component:
    """A sub-assembly of a complex instrument."""
    role: str
    type_designations: list[str] = field(default_factory=list)
    alternatives: str | None = None  # "OR" | "AND" | None
    characteristics: dict[str, Any] = field(default_factory=dict)


@dataclass
class MatrixTable:
    """A multi-dimensional table preserved as structured data."""
    name: str
    columns: list[str] = field(default_factory=list)
    rows: list[dict] = field(default_factory=list)
    description: str | None = None
    footnotes: list[str] = field(default_factory=list)


@dataclass
class TestReport:
    id: str = ""
    date: str | None = None
    pages: int | None = None
    role: str | None = None  # type_evaluation_report | test_report | documentation_file | evaluation_report


@dataclass
class RevisionEntry:
    revision: str = ""
    date: str = ""
    changes: str = ""


@dataclass
class Footnote:
    marker: str = ""
    text: str = ""


@dataclass
class ParsedCertificate:
    """Layered result of extracting one certificate."""

    # Document-level
    certificate: dict = field(default_factory=dict)
    issuing_authority: dict = field(default_factory=dict)
    applicants: list[dict] = field(default_factory=list)
    manufacturers: list[dict] = field(default_factory=list)

    # Certified type / model family / components
    certified_type: dict = field(default_factory=dict)
    model_family: dict | None = None  # {family_name, models[]}
    components: list[Component] = field(default_factory=list)

    # Characteristics (layered by scope)
    characteristics_type_level: dict[str, CharacteristicValue] = field(default_factory=dict)
    characteristics_model_level: list[ModelLevelEntry] = field(default_factory=list)
    characteristics_config_level: list[ConfigLevelEntry] = field(default_factory=list)

    # Structured tables preserved
    matrix_tables: list[MatrixTable] = field(default_factory=list)

    # Reference info
    recommendation: dict = field(default_factory=dict)
    test_reports: list[TestReport] = field(default_factory=list)
    revision_history: list[RevisionEntry] = field(default_factory=list)
    footnotes: list[Footnote] = field(default_factory=list)

    # Extraction metadata
    extraction_warnings: list[str] = field(default_factory=list)

    @classmethod
    def from_json(cls, data: dict) -> "ParsedCertificate":
        """Build from the JSON dict returned by the GLM extractor. Lenient:
        tolerates missing fields, unexpected keys, and shorthand value forms."""
        def _as_dict(x):
            return dict(x) if isinstance(x, dict) else {}
        def _as_list(x):
            return list(x) if isinstance(x, list) else []

        def _characteristic_value(v):
            if isinstance(v, dict):
                # Tolerate legacy "unit" key as alias for unit_symbol
                unit_sym = v.get("unit_symbol") or v.get("unit")
                return CharacteristicValue(
                    value=v.get("value"),
                    unit_symbol=unit_sym,
                    unit_id=v.get("unit_id"),
                    footnote_markers=v.get("footnote_markers", []) or [],
                )
            return CharacteristicValue(value=v)

        def _model_level_entry(e):
            e = e or {}
            return ModelLevelEntry(
                attribute=e.get("attribute", ""),
                unit=e.get("unit") or e.get("unit_symbol"),
                values=e.get("values", []) or [],
            )

        def _config_level_entry(e):
            e = e or {}
            return ConfigLevelEntry(
                attribute=e.get("attribute", ""),
                axis=e.get("axis", ""),
                values=e.get("values", []) or [],
            )

        def _component(c):
            c = c or {}
            return Component(
                role=c.get("role", ""),
                type_designations=c.get("type_designations", []) or [],
                alternatives=c.get("alternatives"),
                characteristics=c.get("characteristics", {}) or {},
            )

        def _matrix_table(t):
            t = t or {}
            return MatrixTable(
                name=t.get("name", ""),
                columns=t.get("columns", []) or [],
                rows=t.get("rows", []) or [],
                description=t.get("description"),
                footnotes=t.get("footnotes", []) or [],
            )

        chars = _as_dict(data.get("characteristics"))
        # GLM occasionally returns these as lists instead of dicts — coerce.
        raw_type_level = chars.get("type_level", {}) or {}
        if isinstance(raw_type_level, list):
            # Convert [{attribute, value, unit}] → {attribute: {value, unit}}
            raw_type_level = {
                e.get("attribute", f"unknown_{i}"): {
                    "value": e.get("value"),
                    "unit": e.get("unit"),
                    "footnote_markers": e.get("footnote_markers", []),
                }
                for i, e in enumerate(raw_type_level)
                if isinstance(e, dict)
            }
        return cls(
            certificate=_as_dict(data.get("certificate")),
            issuing_authority=_as_dict(data.get("issuing_authority")),
            applicants=_as_list(data.get("applicants")),
            manufacturers=_as_list(data.get("manufacturers")),
            certified_type=_as_dict(data.get("certified_type")),
            model_family=data.get("model_family") if isinstance(data.get("model_family"), dict) else None,
            components=[_component(c) for c in _as_list(data.get("components"))],
            characteristics_type_level={
                k: _characteristic_value(v)
                for k, v in raw_type_level.items()
            },
            characteristics_model_level=[
                _model_level_entry(e) for e in chars.get("model_level", []) or []
            ],
            characteristics_config_level=[
                _config_level_entry(e) for e in chars.get("config_level", []) or []
            ],
            matrix_tables=[_matrix_table(t) for t in _as_list(data.get("matrix_tables"))],
            recommendation=_as_dict(data.get("recommendation")),
            test_reports=[
                TestReport(**{k: v for k, v in (t.items() if isinstance(t, dict) else []) if k in {"id", "date", "pages", "role"}})
                for t in _as_list(data.get("test_reports"))
            ],
            revision_history=[
                RevisionEntry(**{k: v for k, v in (r.items() if isinstance(r, dict) else []) if k in {"revision", "date", "changes"}})
                for r in _as_list(data.get("revision_history"))
            ],
            footnotes=[
                Footnote(**{k: v for k, v in (f.items() if isinstance(f, dict) else []) if k in {"marker", "text"}})
                for f in _as_list(data.get("footnotes"))
            ],
            extraction_warnings=data.get("_warnings", []) or [],
        )

    def to_dict(self) -> dict:
        """For serializers. Returns the canonical layered dict. Lenient:
        coerces non-dict fields to {} so PyYAML never blows up on
        malformed GLM output."""
        def _as_dict(x):
            return dict(x) if isinstance(x, dict) else {}
        def _as_list(x):
            return list(x) if isinstance(x, list) else []

        type_level = {}
        for k, v in self.characteristics_type_level.items():
            type_level[k] = {
                "value": v.value,
                "unit_symbol": v.unit_symbol,
                "unit_id": v.unit_id,
                "footnote_markers": list(v.footnote_markers),
            }
        out: dict = {
            "certificate": _as_dict(self.certificate),
            "issuing_authority": _as_dict(self.issuing_authority),
            "applicants": _as_list(self.applicants),
            "manufacturers": _as_list(self.manufacturers),
            "certified_type": _as_dict(self.certified_type),
            "characteristics": {
                "type_level": type_level,
                "model_level": [
                    {"attribute": e.attribute, "unit_symbol": e.unit, "values": _as_list(e.values)}
                    for e in self.characteristics_model_level
                ],
                "config_level": [
                    {"attribute": e.attribute, "axis": e.axis, "values": _as_list(e.values)}
                    for e in self.characteristics_config_level
                ],
            },
            "recommendation": _as_dict(self.recommendation),
            "test_reports": [
                {"id": t.id, "date": t.date, "pages": t.pages, "role": t.role}
                for t in self.test_reports
            ],
            "revision_history": [
                {"revision": r.revision, "date": r.date, "changes": r.changes}
                for r in self.revision_history
            ],
        }
        if self.model_family:
            out["model_family"] = {
                "family_name": self.model_family.get("family_name"),
                "models": self.model_family.get("models", []),
            }
        if self.components:
            out["components"] = [
                {
                    "role": c.role,
                    "type_designations": c.type_designations,
                    "alternatives": c.alternatives,
                    "characteristics": c.characteristics,
                }
                for c in self.components
            ]
        if self.matrix_tables:
            out["matrix_tables"] = [
                {
                    "name": t.name,
                    "columns": t.columns,
                    "rows": t.rows,
                    "description": t.description,
                    "footnotes": t.footnotes,
                }
                for t in self.matrix_tables
            ]
        if self.footnotes:
            out["footnotes"] = [
                {"marker": f.marker, "text": f.text}
                for f in self.footnotes
            ]
        if self.extraction_warnings:
            out["_warnings"] = list(self.extraction_warnings)
        return out
