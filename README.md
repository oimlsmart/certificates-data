# certificates-data

The OIML-CS domain's data home: the complete certificate corpus of the
OIML Certification System — the register, every published document, the
digitalized tiers, and the validated datasets derived from them. The
certificates site (oimlsmart/certificates), the retrieval service
(oimlsmart/ai, serving [ommisa.org](https://www.ommisa.org)), and the
signed-certificate stack (oimlsmart/cnml) are all consumers; none of them
owns a fact. Every fact here traces to a committed raw file, and nothing
on disk ever needs a model call again.

## The tiers

| Tier | Location | What it holds |
| --- | --- | --- |
| Register | `manifest.jsonl` | one row per certificate as the OIML-CS database states it (6,556 rows) |
| Raw PDFs | `certificates/RXXX/YYYY/` | every published document (5,163 files, ~2.9 GB) |
| Vision raws | `ocr_raw/` | the **verbatim** glm-5.3-flash vision response per PDF — model, usage, full transcription (never re-run; this is source) |
| Digitalized | `ocr_md/` | the markdown tier (headers + body), incl. text-layer and Workers-AI recoveries |
| Structured records | `pipeline-work/yaml/` | the layered per-certificate record (5,166 records — every document-bearing certificate) |
| Extraction raws | `extract_raw/`, `reconcile_raw/` | verbatim responses of the structured and adjudication stages |

## The datasets (CI-validated on every change)

- `datasets/certificates/records.jsonl` — **the fused record**: the
  register's own fields + the document's structured content + the
  reconciliation of the two, disagreements adjudicated with committed
  evidence. The agent-facing contract for this dataset:
  `oimlsmart/ai`'s `docs/certificates-dataset-prompt.md`.
- `datasets/history/timelines.jsonl` + `changes.jsonl` — per-certificate
  timelines (register observation + document-stated dates, revision
  tables, supersession) and the change log between snapshots, each record
  citing the register's own certificate page.
- `datasets/organizations/` — issuing authorities and holders resolved by
  stated normalization rules; variants and open questions carry evidence.
- `datasets/reconciliation.jsonl` + `adjudications.jsonl` — the two-surface
  comparison and its model-adjudicated verdicts.
- `datasets/DENOMINATORS.md`, `datasets/QUALITY.md` — generated ledgers:
  coverage and quality, computed from the tiers, never hand-typed.
- `stats/R*.yaml` — per-Recommendation extraction statistics.
- `snapshots/YYYYMMDD/` — the register snapshot lineage (the weekly scrape
  appends; `bin/diff_manifests.rb` turns consecutive snapshots into change
  records).

## The cycle

The weekly scrape (`.github/workflows/scrape.yml`, Mondays 03:17 UTC)
snapshots the current register, re-reads the OIML-CS database, downloads
new documents, and commits. New certificates flow through the extraction
pipeline (`bin/`), the datasets regenerate deterministically, and CI
(`.github/workflows/validate.yml`) validates everything against the
schemas before it merges. History accumulates; nothing is overwritten.

## The laws

- Never delete a source file. Extraction adds; provenance files
  (`.broken`, `.attempt`, `.stale`, `.preunblock`) preserve every prior
  state beside its successor.
- The raw tiers are the permanent source: a committed raw response is
  never re-run through a model; everything downstream derives from it.
- Absence is stated honestly (register-only rows, quarantined register
  defects) — never improvised.
- Model calls use glm-5.3-flash via z.ai's Anthropic-compatible endpoint
  (the GLM Coding Plan covers only that path); the estate's Cloudflare
  Workers AI serves as the second vision provider when the first filters.

New-code law: **Ruby only** in `bin/` and new tooling; the Python under
`oiml_cs/` and `pipeline-work/` is the frozen record of how the corpus was
built and stays untouched.

See `TODO.planes/` for the programme papers (audit, plans) and `bin/`
for the pipeline index.
