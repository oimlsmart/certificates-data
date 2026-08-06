"""ProcessRecommendation (v2): uses GLM extractor (no regex).

Replaces the regex-parsing version. Reads cached GLM-OCR markdown, calls
GlmExtractor, writes layered YAML per cert, synthesizes per-R schema.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from oiml_cs.domain.certificate import Certificate
from oiml_cs.domain.edition import Edition
from oiml_cs.domain.recommendation import Recommendation
from oiml_cs.domain.value_objects import EditionYear, RNumber
from oiml_cs.extraction.glm_extractor import GlmExtractor
from oiml_cs.extraction.parsed_certificate import ParsedCertificate
from oiml_cs.infrastructure.manifest_repository import ManifestRepository
from oiml_cs.ocr.document import MarkdownDocument
from oiml_cs.sampling.stratified_sampler import StratifiedSampler
from oiml_cs.serialization.yaml_serializer import CertificateYamlSerializer


@dataclass
class ProcessRecommendationResult:
    recommendation: Recommendation
    edition: Edition
    cert_count: int
    extracted_count: int
    extraction_error_count: int
    matrix_tables_count: int
    models_count: int
    schema_path: Path | None


class ProcessRecommendation:
    """GLM-extract a single Recommendation's certs and synthesize a per-R schema."""

    def __init__(
        self,
        manifest_repo: ManifestRepository,
        extractor: GlmExtractor,
        output_root: Path,
        sample_size: int = 100,
    ):
        self._repo = manifest_repo
        self._extractor = extractor
        self._out = output_root
        self._sample_size = sample_size
        self._serializer = CertificateYamlSerializer()
        self._sampler = StratifiedSampler(sample_size=sample_size)

    def execute(
        self,
        r_number: RNumber,
        edition_year: EditionYear | None = None,
    ) -> ProcessRecommendationResult:
        if edition_year is None:
            edition_year = self._repo.latest_edition(r_number)
            if edition_year is None:
                raise RuntimeError(f"No editions found for {r_number}")
        edition = self._repo.edition(r_number, edition_year)

        certs = self._repo.certificates_for(r_number, edition_year)
        sampled = self._sampler.sample(certs)

        parsed_certs: list[ParsedCertificate] = []
        error_count = 0
        matrix_tables_count = 0
        models_count = 0
        for i, cert in enumerate(sampled, 1):
            try:
                parsed, errored = self._process_one_cert(cert, edition)
                parsed_certs.append(parsed)
                if errored:
                    error_count += 1
                matrix_tables_count += len(parsed.matrix_tables)
                if parsed.model_family:
                    models_count += len(parsed.model_family.get("models", []))
            except Exception as e:
                error_count += 1
                print(f"  ERROR {cert.num}: {e}")
            if i % 10 == 0 or i == len(sampled):
                print(f"  [{r_number}/{edition.year}] {i}/{len(sampled)}  (errors so far: {error_count})")

        schema_path = self._write_summary_schema(r_number, edition_year, parsed_certs)

        return ProcessRecommendationResult(
            recommendation=Recommendation(r_number),
            edition=edition,
            cert_count=len(certs),
            extracted_count=len(parsed_certs),
            extraction_error_count=error_count,
            matrix_tables_count=matrix_tables_count,
            models_count=models_count,
            schema_path=schema_path,
        )

    def _process_one_cert(self, cert: Certificate, edition: Edition) -> tuple[ParsedCertificate, bool]:
        """Extract + serialize a single cert. Returns (parsed, errored)."""
        md_path = self._out / "ocr_md" / edition.path_segment() / f"{cert.stem}.md"
        if not md_path.exists():
            raise FileNotFoundError(f"No GLM-OCR markdown for {cert.num}: {md_path}")
        doc = MarkdownDocument.from_file(md_path, cert)
        parsed = self._extractor.extract(doc)
        errored = bool(parsed.extraction_warnings)
        self._write_yaml(cert, edition, parsed)
        return parsed, errored

    def _write_yaml(self, cert: Certificate, edition: Edition, parsed: ParsedCertificate) -> None:
        yaml_path = self._out / "yaml" / edition.path_segment() / f"{cert.stem}.yaml"
        yaml_path.parent.mkdir(parents=True, exist_ok=True)
        yaml_path.write_text(self._serializer.serialize(cert, parsed), encoding="utf-8")

    def _write_summary_schema(
        self,
        r_number: RNumber,
        edition_year: EditionYear,
        parsed_certs: list[ParsedCertificate],
    ) -> Path:
        """Write a per-R summary: type_level characteristic vocab grouped by unit."""
        from collections import Counter, defaultdict
        from oiml_cs.units import UnitsDb

        units_db = UnitsDb()
        # attribute -> unit_symbol -> [raw values]
        type_level: dict[str, dict[str | None, list]] = defaultdict(lambda: defaultdict(list))
        model_level_attrs: Counter = Counter()
        config_level_attrs: Counter = Counter()
        matrix_table_names: Counter = Counter()

        def _coerce_value(v):
            """Normalize a value for stat counting: numbers stay numbers,
            ranges become frozenset items, strings stay strings."""
            return v

        for p in parsed_certs:
            for label, cv in p.characteristics_type_level.items():
                if cv.value is None:
                    continue
                # Resolve unit_symbol → unit_id via unitsdb
                unit_sym = cv.unit_symbol
                unit_id = cv.unit_id
                if unit_sym and not unit_id:
                    entry = units_db.unit_for_symbol(unit_sym)
                    if entry:
                        unit_id = entry.unit_id
                type_level[label][unit_sym or None].append({
                    "value": cv.value,
                    "unit_id": unit_id,
                })
            for entry in p.characteristics_model_level:
                model_level_attrs[entry.attribute] += 1
            for entry in p.characteristics_config_level:
                config_level_attrs[entry.attribute] += 1
            for mt in p.matrix_tables:
                matrix_table_names[mt.name] += 1

        n = len(parsed_certs)

        # Build per-attribute section grouped by unit
        type_level_section: dict[str, dict] = {}
        for attr, by_unit in type_level.items():
            total_count = sum(len(vs) for vs in by_unit.values())
            if total_count == 0:
                continue
            attr_entry: dict = {
                "fill_rate": round(total_count / n, 3) if n else 0,
                "present_count": total_count,
            }
            # If all values share the same unit, hoist it to attribute level
            if len(by_unit) == 1:
                only_unit = next(iter(by_unit.keys()))
                only_values = next(iter(by_unit.values()))
                # Try to resolve unit_id from the first value
                unit_id = only_values[0].get("unit_id") if only_values else None
                attr_entry["unit_symbol"] = only_unit
                if unit_id:
                    attr_entry["unit_id"] = unit_id
                attr_entry["top_values"] = self._top_numeric_values(only_values)
            else:
                # Multiple units — show grouped by unit
                attr_entry["by_unit"] = {}
                for unit_sym, values in sorted(by_unit.items(), key=lambda kv: -(len(kv[1]))):
                    unit_id = values[0].get("unit_id") if values else None
                    sub: dict = {
                        "count": len(values),
                        "top_values": self._top_numeric_values(values),
                    }
                    if unit_id:
                        sub["unit_id"] = unit_id
                    attr_entry["by_unit"][unit_sym or "null"] = sub
            type_level_section[attr] = attr_entry

        schema = {
            "recommendation": str(r_number),
            "edition": edition_year.value,
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

        schema_dir = self._out / "schema"
        schema_dir.mkdir(parents=True, exist_ok=True)
        path = schema_dir / f"{r_number}.yaml"
        path.write_text(
            yaml.safe_dump(schema, allow_unicode=True, sort_keys=False, default_flow_style=False, width=100),
            encoding="utf-8",
        )
        return path

    @staticmethod
    def _top_numeric_values(values: list[dict], limit: int = 10) -> list[dict]:
        """Show value distribution as numbers/ranges, not strings."""
        from collections import Counter
        # The values are list of {value: num|{min,max}|str, unit_id}
        scalar_counts: Counter = Counter()
        range_counts: Counter = Counter()
        string_counts: Counter = Counter()
        for v in values:
            val = v.get("value")
            if isinstance(val, dict) and ("min" in val or "max" in val):
                key = f"min={val.get('min')}, max={val.get('max')}"
                range_counts[key] += 1
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


# Lazy import to avoid pulling yaml into module-level deps for typing only
import yaml  # noqa: E402
