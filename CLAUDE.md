# CLAUDE.md

Guidance for AI agents (Claude Code and others) working in this repository.

## What this repository is

The OIML-CS domain's data home: the certificate register, every published
document, the digitalized tiers, and the validated datasets derived from
them. Consumers (oimlsmart/ai, oimlsmart/certificates, oimlsmart/cnml) pin
this repository's commits and own no facts of their own. Read `README.md`
for the tier and dataset map before doing anything.

## Hard laws

1. **Never delete a source file.** Extraction adds; it never removes.
   Superseded artifacts are renamed aside (`.broken`, `.attempt`, `.stale`,
   `.preunblock`, `.pagemarkdown`) beside their successors. Provenance is
   never garbage-collected.
2. **Never re-run a model on a committed raw.** `ocr_raw/`, `extract_raw/`,
   and `reconcile_raw/` hold verbatim API responses — every dataset
   regenerates from them deterministically. A model call happens only where
   no raw exists.
3. **All changes go through PRs; never commit to main, never push tags,
   never merge without the maintainer's word.** CI (`validate.yml`) must be
   green — it validates the datasets against their schemas and the tier
   joins; a failure blocks, never ships.
4. **New code is Ruby** (`bin/*.rb`). The Python under `oiml_cs/` and
   `pipeline-work/` is the frozen record of the original build — read it
   (the extraction SYSTEM_PROMPT is loaded verbatim from
   `oiml_cs/extraction/glm_extractor.py` at runtime), never extend it.
5. **`TODO.planes/` stays out of commits** unless the maintainer says
   otherwise (their standing rule).
6. **Absence is stated, never improvised.** Register-only rows,
   quarantined register defects (`datasets/certificates/register-defects.json`),
   and any unrecoverable content are carried honestly in the data.

## Model calls (when unavoidable)

- glm-5.3-flash via **z.ai's Anthropic-compatible endpoint**
  (`https://api.z.ai/api/anthropic/v1/messages`, `x-api-key` +
  `anthropic-version: 2023-06-01`, `max_tokens` ≥ 30000 — the model is a
  native reasoner whose thinking consumes budget). The accounts are GLM
  Coding Plans: the OpenAI-style `v4/chat/completions` path returns
  insufficient-balance regardless of credit.
- HTTP 429 / error 1302 are rate limits: retry with generous backoff
  (20s × attempt), never instant-fail.
- z.ai's content filter rejects some page renders; the recovery ladder is:
  smaller rasters → JPEG → quadrant crops → the PDF's embedded text layer
  (`mutool draw -F text`, no model at all) → Cloudflare Workers AI
  (`@cf/meta/llama-3.2-11b-vision-instruct` via the estate's wrangler
  OAuth token; accepts its license with one `{"prompt":"agree"}` call).
  Every recovery records its strategy in the raw.
- Dense documents that break single-shot JSON (thinking exhausts the token
  ceiling mid-emission) go through `bin/split_extract.rb` (chunk, extract
  per fragment with the frozen prompt, deep-merge).

## The pipeline (bin/)

Read `bin/README.md`. The regeneration order after any tier change:
`extract_history` → `build_organizations` → `reconcile_records` →
`adjudicate_conflicts` (only new conflicts) → `build_fused_records` →
`build_stats` → `quality_report` → `denominators_report` →
`validate_datasets` (must pass).

## The weekly cycle

Mondays 03:17 UTC the scrape workflow snapshots and refreshes the
register; cnml's `count-sync` follows an hour later. Datasets regenerate
over whatever exists. Nothing waits on a human.
