# The denominators report
# generated: 2026-10-10T07:24:37Z

The register (manifest.jsonl)                       6476 rows
Document-backed rows (local_path)                   5109
Distinct PDFs on disk                               5085
Register-only rows (no file ever existed)           1367

Vision tier: raws committed                          4117
  + legacy md-era extractions                        971 (approx; md files without vision raws)
  filter-blocked certificates (page-level markers)   2

Structured records (pipeline-work/yaml)             5088
  coverage of document-backed rows                   100.1%

History dataset: rows                                6476
  rows with a joined document                        5109 (78.9% of register)

Organizations dataset: entities                      1628

Completion arithmetic:
  6476 register rows
    = 5085 document-backed  → vision-extracted via glm-5.3-flash + 971 legacy
      → 5088 structured records today
    + 1367 register-only rows (name, applicant, year, status — no document exists)
