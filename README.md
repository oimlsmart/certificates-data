# OIML-CS Certificates

A Python pipeline for downloading OIML-CS (OIML Certification System)
certificates, OCR'ing them with GLM-OCR, parsing into structured YAML,
and synthesizing per-Recommendation schemas.

## What this project does

1. **Downloads** all OIML-CS certificates (~6,500 PDFs, ~3 GB) from
   `oiml.org` via an undocumented JSON API.
2. **Organizes** them on disk by Recommendation (R-number) and edition
   year, mirroring the OIML Recommendation structure.
3. **OCRs** a stratified sample of up to 100 certificates per
   Recommendation's latest edition using GLM-OCR (z.ai layout_parsing API).
4. **Parses** the OCR markdown into structured per-cert YAML files.
5. **Synthesizes** a per-Recommendation YAML schema from the parsed data.

## Project layout

```
oiml-cs-certificates/
├── oiml_cs/                # Library: domain-driven, OOP, generic
│   ├── domain/             # Value objects: RNumber, EditionYear, Issuer, Certificate
│   ├── infrastructure/     # ManifestRepository (single source of truth)
│   ├── ocr/                # OcrSource ABC + GlmOcrSource + PymupdfOcrSource
│   ├── parsing/            # Markdown → ParsedCertificate (table-driven, R-agnostic)
│   ├── sampling/           # StratifiedSampler
│   ├── serialization/      # CertificateYamlSerializer
│   ├── schema/             # SchemaSynthesizer + SchemaRenderer
│   └── use_cases/          # ProcessRecommendation (orchestrator)
├── scripts/                # CLI entry points
│   ├── process_all.py      # all R-numbers
│   ├── process_one.py      # single R-number
│   ├── ocr_with_glm.rb     # standalone Ruby GLM-OCR driver (legacy)
│   └── download_certs.py   # (planned) wrap download_oiml_certs.py
├── spec/                   # pytest specs (no doubles, real fixtures)
├── certificates/           # Downloaded PDFs, organized as R<NN>/<edition>/<file>.pdf
├── ocr_md/                 # GLM-OCR markdown, mirrored layout
├── yaml/                   # Parsed per-cert YAML, mirrored layout
├── schema/                 # Per-R schema YAML + JSON stats
├── manifest.jsonl          # Authoritative index (6,476 rows)
├── TODO.refactor/          # Architectural plan and status (11 docs)
└── _archive/               # Superseded scripts (kept for history)
```

## Quick start

```sh
# One-time: download all PDFs (~3 GB)
python3 download_oiml_certs.py

# OCR + parse + schema for all R-numbers' latest edition
python3 scripts/process_all.py

# Or just one R
python3 scripts/process_one.py --r R60
```

Re-running is safe and idempotent: cached OCR responses in `_glm_ocr_cache/`
are reused, already-OCR'd certs are skipped.

## Architecture principles

- **Model-driven.** Domain value objects (`RNumber`, `EditionYear`,
  `Certificate`) drive everything. Callers consume domain objects, never
  raw JSON rows.
- **Open/Closed.** New R-number = just run the pipeline on it; no code
  changes. The parser is generic — it captures tables as label→value
  without knowing R-specific fields.
- **MECE.** Each concern lives in exactly one place: parsing in
  `oiml_cs/parsing/`, OCR in `oiml_cs/ocr/`, sampling in `oiml_cs/sampling/`,
  etc.
- **DRY.** The HTML table extractor is shared by all section parsers.
  The `_FILE_NAME_RE` regex lives once in `domain/certificate.py`.
- **No hand-rolled serialization.** Per CLAUDE.md: PyYAML is the framework.
  Models are plain dataclasses; the serializer reads their fields.
- **Specs without doubles.** `spec/` uses real manifest data and real
  GLM-OCR markdown fixtures.

## API keys

GLM-OCR is called via `https://api.z.ai/api/paas/v4/layout_parsing`. The
key is read from `~/.zai-api-key` (or `Z_AI_API_KEY` env var).

## Cache

`_glm_ocr_cache/<sha>.json` — keyed by SHA256 of (pdf_path, start_page,
end_page). Cache files written by either the Python `GlmOcrSource` or the
Ruby `GlmOcr` library are interchangeable.

## Specs

```sh
python3 -m pytest
```

54 specs across domain, manifest repo, parser, schema, sampler, serializer.
