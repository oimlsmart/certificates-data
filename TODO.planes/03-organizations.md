# 03 — The organizations dataset

The institutional facts the register's own documents carry, extracted
into the domain's organizations plane: who issues, who notifies, who
holds.

## The sources in this repository

- The issuing-authority block in the digitalized certificates' bodies:
  the name (national language + English), the country, the address, the
  notified body number. Sample: `ocr_md/R105/1993/r105-1993-no1-2006.01.md`
  carries "Justervesenet (N), Norwegian Metrology Service (E)", Fetveien
  99, N-2007 Kjeller, notified body no. 0431.
- The manifest's `applicant` field: the holder organization's name as
  the register spells it.
- The `issuer` header in the OCR files' comment block (the issuing
  authority's code, e.g. NO1).

## The work

1. The organization record: a stable id, the kind (issuing authority /
   notified body / holder), the names (per language), the country, the
   address where the documents state one, the notified body number where
   present, and the provenance (the certificate nums that attest each
   fact — an organization's record cites its evidence).
2. The normalization rules, stated as data: name variants collapse by
   rule (spelling, translation pairs like the Norwegian/English doublets),
   never by ad-hoc judgment; the unresolved variants stay distinct and
   are listed in the dataset's open-questions section.
3. The extraction pipeline lands in `oiml_cs/` (the existing library's
   domain-driven layout); the dataset ships as `datasets/organizations/`
   (JSONL + schema), CI-validated.
4. The coverage report: how many of the 6,476 certificates' authority
   blocks extracted cleanly, how many need model assistance, and the
   blind spots stated plainly.

## The consumers

The retrieval service serves holder and authority questions from this
plane (the certificates.search tool's rows gain authority provenance);
the certificates site renders the authority pages from it.
