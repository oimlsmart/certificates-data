# The pipeline index

Every script is idempotent and regenerates its output from the tiers on
disk. Raw-producing stages call models only where no raw exists.

## Extraction stages (model-backed, raws committed)

| Script | Stage | Notes |
| --- | --- | --- |
| `finish_pdfs.rb` | PDF → vision raw + md | glm-5.3-flash per PDF; resumable; never overwrites |
| `extract_structured.rb` | md → layered record | frozen SYSTEM_PROMPT verbatim; `--refetch` re-calls parse-broken raws (old kept as `.attemptN`) |
| `split_extract.rb` | dense docs → chunked records | for JSON-breaking documents; fragments as `.partK`, originals as `.broken` |
| `extract_blocked_per_page.rb` | filter-blocked PDFs → per-page raws | marks unrecoverable pages honestly |
| `unblock_via_workers_ai.rb` | blocked pages via Cloudflare | Llama 3.2 vision; the second provider shares no filter |
| `adjudicate_conflicts.rb` | reconciliation layer two | one verdict per conflicting axis; raws in `reconcile_raw/` |
| `repair_broken_json.rb` | model-assisted JSON repair | broken originals kept as `.broken` |

## Deterministic builders (no models)

| Script | Output |
| --- | --- |
| `reconcile_records.rb` | `datasets/reconciliation.jsonl` (layer one) |
| `build_fused_records.rb` | `datasets/certificates/records.jsonl` (the fused record) |
| `extract_history.rb` | `datasets/history/timelines.jsonl` |
| `diff_manifests.rb` | `datasets/history/changes.jsonl` (snapshot pairs) |
| `build_organizations.rb` | `datasets/organizations/` |
| `build_stats.rb` | `stats/R*.yaml` |
| `enrich_register_only.rb` | `datasets/certificates/register-only-enrichment.jsonl` |
| `backfill_units.rb` | unit_id backfill from the unitsdb checkout |
| `backfill_record_gaps.rb` | authority/member-state from the mds (provenance-marked) |
| `backfill_md_headers.rb` | md header repair from the manifest |
| `rederive_meta.rb` | record `_meta` rebuild from raws |

## Quality and operations

| Script | Purpose |
| --- | --- |
| `validate_datasets.rb` | schema + join validation (CI runs it) |
| `quality_report.rb` | `datasets/QUALITY.md`, generated |
| `denominators_report.rb` | `datasets/DENOMINATORS.md`, generated |
| `closing_sweep.sh` | the full retry-and-regenerate sequence |
| `endgame.sh` | coverage-gated commit helper (historical; review before reuse) |
| `recover_textlayer.rb`, `rebuild_from_textlayer.rb`, `unblock_pages.rb` | the text-layer recovery ladder (historical runs) |

## Regeneration order after any tier change

```
extract_history → build_organizations → reconcile_records →
adjudicate_conflicts (new conflicts only) → build_fused_records →
build_stats → quality_report → denominators_report → validate_datasets
```
