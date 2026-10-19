# The denominators report
# generated: 2026-10-19T09:09:16Z

The register (manifest.jsonl)                       6556 rows
Document-backed rows (local_path)                   5187
Distinct PDFs on disk                               5163
Register-only rows (no file ever existed)           1369

Vision tier: raws committed                          4204
  + legacy md-era extractions                        962 (approx; md files without vision raws)
  filter-blocked certificates (page-level markers)   0

Structured records (pipeline-work/yaml)             5166
  coverage of document-backed rows                   100.1%

History dataset: rows                                6556
  rows with a joined document                        5187 (79.1% of register)

Organizations dataset: entities                      1640

Completion arithmetic:
  6556 register rows
    = 5163 document-backed  → vision-extracted via glm-5.3-flash + 962 legacy
      → 5166 structured records today
    + 1369 register-only rows (name, applicant, year, status — no document exists)
