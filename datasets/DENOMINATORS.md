# The denominators report
# generated: 2026-10-11T07:47:52Z

The register (manifest.jsonl)                       6556 rows
Document-backed rows (local_path)                   5187
Distinct PDFs on disk                               5163
Register-only rows (no file ever existed)           1369

Vision tier: raws committed                          4205
  + legacy md-era extractions                        961 (approx; md files without vision raws)
  filter-blocked certificates (page-level markers)   14

Structured records (pipeline-work/yaml)             5166
  coverage of document-backed rows                   100.1%

History dataset: rows                                6556
  rows with a joined document                        5109 (77.9% of register)

Organizations dataset: entities                      1637

Completion arithmetic:
  6556 register rows
    = 5163 document-backed  → vision-extracted via glm-5.3-flash + 961 legacy
      → 5166 structured records today
    + 1369 register-only rows (name, applicant, year, status — no document exists)
