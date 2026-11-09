# The denominators report
# generated: 2026-11-09T11:51:01Z

The register (manifest.jsonl)                       6595 rows
Document-backed rows (local_path)                   5226
Distinct PDFs on disk                               5202
Register-only rows (no file ever existed)           1369

Vision tier: raws committed                          4204
  + legacy md-era extractions                        962 (approx; md files without vision raws)
  filter-blocked certificates (page-level markers)   0

Structured records (pipeline-work/yaml)             5166
  coverage of document-backed rows                   99.3%

History dataset: rows                                6595
  rows with a joined document                        5187 (78.7% of register)

Organizations dataset: entities                      1642

Completion arithmetic:
  6595 register rows
    = 5202 document-backed  → vision-extracted via glm-5.3-flash + 962 legacy
      → 5166 structured records today
    + 1369 register-only rows (name, applicant, year, status — no document exists)
