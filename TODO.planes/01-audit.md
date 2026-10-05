# 01 — The audit: what the corpus already carries

Produce `TODO.planes/audit-findings.md` — an evidence-backed census of
every fact family the corpus already holds, with counts and samples.
Nothing here is invented; every claim cites a file and a field.

## What to census

1. **The manifest** (`manifest.jsonl`, 6,476 rows): the identity fields
   (num, name, applicant, issuingYear, status, idStatus), their
   completeness, their distinct-value distributions, and the anomalies
   (null fileName, download_status values, duplicate nums if any).
2. **The digitalized tier** (`ocr_md/RXXX/YYYY/*.md`): the HTML comment
   headers (cert_id, num, applicant, issuing_year, status, issuer,
   extraction_method, source_pdf) — their consistency with the manifest,
   and the BODY's extractable families: the issuing-authority block
   (name, country, address, notified body number), the certificate's
   instrumental scope (the Recommendation and the instrument), the
   holder/applicant distinctions the documents themselves make.
3. **The per-Recommendation schemas** (`schema/*.yaml`): what each
   family's synthesized schema captures, and where the families disagree.
4. **The statistics** (`stats/`): what fill rates already measure, and
   what the planes programme should additionally measure.

## The deliverable's shape

For each fact family: the field list, the coverage percentage, three
sample values, the extraction difficulty (trivial / table-driven / needs
model assistance), and which plane (02/03/04) it belongs to.
