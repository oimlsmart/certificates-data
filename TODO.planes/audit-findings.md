# 01 — The audit: what the corpus already carries

This document is the evidence-backed census the programme's first plane
calls for. Every number below was computed mechanically from the files
this repository holds, and every claim cites a file and a field. The
census covers the four sources the plan names — the manifest, the
digitalized tier, the per-Recommendation schemas, and the statistics —
plus the two further tiers the audit found on disk and considers
load-bearing for the plans: the raw PDF tier (`certificates/`) and the
extracted per-certificate record tier (`pipeline-work/yaml/`), which the
statistics files measure and without which plans 02 and 03 would rest on
the manifest alone.

The counts in this document were computed with throwaway Ruby census
scripts against the working tree at the state of the commit this file
lands in. Where a claim depends on a specific row, the row is cited by
`id` so it can be checked with a single filter over `manifest.jsonl`.

## The tiers and their coverage, stated once

| Tier | Location | Count | Covers |
| --- | --- | --- | --- |
| Raw PDFs | `certificates/RXXX/YYYY/*.pdf` | 5,085 files, 2.8 GB | 78.9% of the 6,476 manifest rows (5,109 rows carry `local_path`; 24 PDFs serve two rows each through the duplicate nums of Finding M5) |
| Digitalized | `ocr_md/RXXX/YYYY/*.md` | 1,063 files = 963 primary + 100 backup | 14.9% of manifest rows (primary tier) |
| Extracted records | `pipeline-work/yaml/RXXX/YYYY/*.yaml` | 880 files | 13.6% of manifest rows; every one pairs with a primary md of the same name |
| Per-R schemas | `schema/R*.yaml` | 22 files + `_core.yaml`, `_common_certificate_schema.yaml`, `_modules/`, `_units*.yaml` | All 22 families that hold digitalized content |
| Statistics | `stats/R*.yaml` | 22 files | The extracted tier, family by family |

The raw tier reconciles exactly with the manifest: all 5,109
`local_path` values exist on disk, and no PDF on disk goes unreferenced
(0 missing, 0 unlisted; the 24-file difference between the two counts is
the duplicate nums sharing a PDF, Finding M5).

The extracted tier pairs one-to-one with the digitalized tier except in
one family: 83 primary md files of R76 have no same-named yaml (all
other families pair completely; 0 yaml files lack their md).

## M — The manifest fact families (`manifest.jsonl`, 6,476 rows)

The manifest carries exactly ten fields: `id`, `num`, `name`,
`applicant`, `fileName`, `issuingYear`, `idStatus`, `status`,
`download_status`, `local_path`. No row carries any other key.

### M1. The identity fields — plane 02

Fields: `id`, `num`. Coverage 100% (6,476 of 6,476 rows each).
`id` values are unique integers (0 duplicate ids). `num` values are not
unique — see Finding M5.

Sample values of `num`:
`"R031/1995-FR1-1999.01"` (id 1), `"R117/2019-A-NL1-21.06 Rev. 0"` (id
5390), `"R76/2006-A-DK2-25.03"` (id 6563).

The num strings vary in shape more than the consumer contract (06)
assumes:

- 2,093 rows carry a `" Rev. N"` suffix inside `num` itself
  (zero-padded and unpadded variants both occur: `" Rev. 0"` 437 rows,
  `" Rev. 01"` 9, `" Rev. 1"` 1,013, `" Rev. 10"` 9, through
  `" Rev. 15"` 1). 33 rows carry an `" Annex. N"` suffix, 11 of them
  combined with a Rev suffix — for example
  `R60/2000-A-NL1-16.20 Annex. 1` (id 6502, download_status `404`).
  In total 2,126 of 6,476 nums carry a suffix; 4,350 carry none.
- 2,158 rows carry an era marker segment `-A-` (2,034) or `-B-` (124)
  between the Recommendation year and the issuer code; the documents
  themselves explain the marker as the OIML-CS scheme
  ("This OIML Certificate is issued under scheme A" appears in 620
  primary md bodies — Finding O7).
- The Recommendation segment carries leading zeros inconsistently:
  9 families appear in both forms (for example R076 in 1,847 rows and
  R76 in 792; R060 in 1,202 and R60 in 425). The 32 raw R-prefix
  strings collapse to 23 canonical families.
- 4 rows carry malformed serials: `"R051/1996-FI--004..1"` (id 1342,
  missing issuer code, doubled dot), `"R076/2006-NL1-2014."` (id 3512),
  `"R129/2000-NL1-2013."` (id 3595), and
  `"R076/2006--2015.01 Rev. 1"` (id 4428, missing issuer code
  entirely).
- The issuer-code segment inside `num` yields 29 distinct codes
  (NL1 3,759 rows, GB1 734, DE1 516, CN1 123, CN2 55, IT2 8, RO1/PL1/
  BG1/NZ1/US1/BE1/KR1/FI1 1–4 each); 3 rows yield no code at all (the
  malformed serials above).

Extraction difficulty: trivial to carry, but the identity rule is not
trivial — see Finding G1.

### M2. The register's descriptive fields — plane 02

Fields: `name`, `applicant`, `issuingYear`.

- `name`: 100% (6,476). Samples: `"Modèle GALLUS 1000 - G1,6
  (Schlumberger)"` (id 1); `"Automatic level gauge - Type: NMR81 and
  NMR84"` (id 5073); `"WS"` (id 3840). 4,094 names embed `"Type:"` and
  245 embed a `Mod(el|èle)` marker, so the instrument designation rides
  inside the name string rather than in its own field.
- `applicant`: 99.92% (6,471 non-empty; 5 rows carry the empty string:
  ids 3191, 3329, 3482, 3840, 4546). 1,154 distinct strings.
- `issuingYear`: 100%, string-typed, range 1993–2026 plus one
  impossible value: id 6683 (`R76/2006-A-DE1-18.6`) carries `issuingYear
  "2029"` while its own `fileName` says `r76-2006-de1-2018-6.pdf` —
  see Finding G6.

Extraction difficulty: trivial.

### M3. The status fields — planes 02 and 04

Fields: `status`, `idStatus`. Coverage 100% each. The observed value
set is exactly two states: `"Valid"` 6,475 rows and `"Suspended"` 1 row
(id 5073, `R85/2008-B-NL1-20.01`). `idStatus` is 1 on every `"Valid"`
row and 0 on the `"Suspended"` row, so the pair is one boolean observed
twice, not two independent facts. `_common_certificate_schema.yaml`'s
`_meta.status` comment anticipates `"Withdrawn"` as well; the data does
not carry it (see Finding G4).

The corpus holds both an A-variant and a B-variant of the same
underlying certificate as separate rows: `R85/2008-A-NL1-20.01` (id
5243, Valid, Revs 1–4 as further rows) and `R85/2008-B-NL1-20.01`
(id 5073, Suspended). The digitalized tier's md for this certificate
(`ocr_md/R85/2008/r085-2008-nl1-2020-01.md`) carries the A-variant num
and header status `"Valid"`; it belongs to id 5243 (`cert_id: 5243`),
not to the suspended B row, so the header and manifest disagree nowhere
here — but the suspended state is invisible in the digitalized tier.

Supersession language: exactly one row in the whole manifest embeds a
supersession notice, id 3191
(`R076/2006-CN1-2013.05`, `name` = `"Superseded by
R076/2006-CN1-2013.05 Rev1"`, `applicant` and `fileName` empty
strings, `download_status` `no_file`). No other row of the 6,476
carries withdrawn/cancelled/revoked/expired language in `name` or
`applicant`. See Finding G5.

Extraction difficulty: trivial to carry; the vocabulary question is
deferred to plan 04 and gated by Finding G4.

### M4. The file-provenance fields — plane 02

Fields: `fileName`, `local_path`, `download_status`.

- `fileName`: 79.2% (5,129). One of those is the empty string (id 3191,
  the supersession row), so 5,128 real file names.
- `local_path`: 78.89% (5,109). Every row with `local_path` also has
  `fileName`; no row has the reverse gap except id 3191's empty-string
  case.
- `download_status`: 100%; observed values: `downloaded` 5,106,
  `no_file` 1,347, `404` 20, `exists` 3. The `404` and `exists` rows
  all carry `fileName` without `local_path`, except the 3 `exists`
  rows, which do have `local_path` (ids 4570, 5073, 6563).

Null `fileName` rows distribute over 14 families, dominated by R076
(623), R060 (412), R051 (112), R117 (48), R061 (58), R031 (24), R085
(24).

Extraction difficulty: trivial.

### M5. `id` ↔ `num` is many-to-one in 23 cases — planes 02 and 06

23 distinct `num` values appear on 2 rows each (46 rows total). 3 of
the pairs are fully identical after ignoring `id`; 20 differ in
payload:

- `name` only: 8 pairs (for example ids 3273/3349,
  `"Marsden M-300 - Baby Scale"` vs `"Maersden M-300 - Baby Scale"` —
  a register-side spelling drift).
- `name` + `issuingYear`: 5 pairs (for example ids 3855/3881, years
  2015 vs 2016 on the same `fileName`).
- `name` + `applicant`: 5 pairs; two of these are substantive
  instrument changes, not spelling (ids 3411/3612: "Bending beam load
  cell … Type Z6" vs "Compression load cell … Type: RC3"; ids
  4086/4396: "Ultrasonic Gas Meter … Senior Sonic" vs "Diaphragm gas
  meter … JK/G2.5 & JK/G1.6").
- `name` + `applicant` + `fileName` + `issuingYear` + `local_path`:
  2 pairs (ids 5396/5871, 5510/6172) — two revisions of the same num
  pointing at differently named PDFs.
- `name` + `download_status`: 1 pair (ids 6517/6563; the second row's
  `download_status` is `exists` with the same `fileName`).

The extraction tier resolved these by content: for
`R137/2012-A-NL1-24.05 Rev. 0` the record
`pipeline-work/yaml/R137/2012/r137-2012-nl1-2024-05-rev0.yaml` carries
`_meta.cert_id: 6404` (the "Ultrasonic water meter" row) whose applicant
matches the document, not id 6280. See Finding G1.

### M6. The year field contradicts the document in one case — plane 02

`pipeline-work/yaml/R76/2006/r076-2006-gb1-2013-02.yaml` carries
`_meta.issuing_year: 2013` against the manifest's `issuingYear: 2014`
for `R076/2006-GB1-2013.02` (id 3273/3349 family). All other 879
extracted records agree with the manifest on the year. The register's
year is a claim the documents can contradict; see Finding G6.

### M7. The applicant field's two surfaces — plane 03

For 9 of the 880 extracted records, the document-stated applicant name
differs from the manifest's spelling, and the yaml tier preserves the
document's form while `_meta.applicant` is nominally a copy of the
manifest's. Examples:

- `pipeline-work/yaml/R137/2012/r137-2012-nl1-2020-14-rev5.yaml`
  (and rev6, rev9): yaml `"Micro Motion, Inc."` vs manifest
  `"Micro Motion, Inc"`.
- `pipeline-work/yaml/R137/2012/r137-2012-nl1-2020-16-rev1.yaml`
  (and rev2, rev4): yaml `"KROHNE Altometer"` vs manifest
  `"Krohne Altometer"`.
- `pipeline-work/yaml/R137/2012/r137-2012-nl1-2021-05-rev2.yaml`:
  yaml `"Endress+Hauser SICK GmbH+Co. KG"` vs manifest
  `"Endress+Hauser SICK Engineering GmbH"` — a substantive difference,
  not spelling.
- `pipeline-work/yaml/R61/2017/r61-2017-cn2-2024-01.yaml`: yaml
  `"Guangdong Kenwei Intellectualised Machinery Co., Ltd "` vs manifest
  `"Guangdong Kenwei Intellectualized Machinery Co., Ltd "`.

This is the organization-variant evidence plan 03's normalization rules
exist to consume. See Finding G2.

## O — The digitalized tier (`ocr_md/`, 1,063 files)

963 primary files plus a 100-file backup directory
(`ocr_md/R76/2006-pymupdf-backup/`, `extraction_method: fitz` on all
100). Every backup file differs from its same-named primary — the
backup is a preserved alternate extraction of the same PDFs, not a
copy. The primary tier's header provenance: `glm-ocr` 952, `pymupdf`
6, `error` 5.

### O1. The HTML comment header block — plane 02

Every one of the 1,063 files carries all eight header fields (1,063 of
1,063 for each of `cert_id`, `num`, `applicant`, `issuing_year`,
`status`, `issuer`, `extraction_method`, `source_pdf`), as HTML
comments in the first lines, in the form
`ocr_md/R105/1993/r105-1993-no1-2006-01.md:1-8`.

Consistency with the manifest, checked mechanically for all 963 primary
files:

- `num`: 963/963 resolve to a manifest row by exact string match (the
  corpus holds both prefix forms as distinct manifest nums, M1; the
  md directory names use the canonical short form — the file
  `ocr_md/R21/2007/r021-2007-gb1-2016-01.md` carries header num
  `R021/2007-GB1-2016.01`, which is the manifest's own spelling).
- `cert_id`: 958/963 match the manifest row's `id`; the 5 that do not
  are exactly the duplicate-num pairs of Finding M5, where the md pins
  the earlier row's id while the naive num lookup lands on the later
  one.
- `applicant`: 963/963 equal the manifest's `applicant` after
  surrounding-whitespace normalization. Zero substantive differences.
- `issuing_year`: 963/963 match `issuingYear`.
- `status`: 963/963 are `"Valid"`, matching the manifest's snapshot.
- `issuer`: 963/963 equal the issuer code embedded in `num`.
- `source_pdf`: 960/960 non-empty values equal the manifest's
  `local_path`; 3 files carry an empty `source_pdf` and a body of
  `<!-- no PDF -->` (`ocr_md/R117/2019/r117-2019-nl1-2021-06-rev0.md`,
  `ocr_md/R51/2006/r51-2006-de1-2022-02-rev1.md`,
  `ocr_md/R60/2021/r60-2021-nl1-2025-56-rev0.md` — the 404 rows of the
  manifest).

The 5 `error` files split into the 3 no-PDF stubs above plus 2
rate-limit failures that carry a real `source_pdf` and the body
`<!-- OCR ERROR: GLM-OCR error: {'error': {'code': '1302', 'message':
'Rate limit reached for requests'}} -->`
(`ocr_md/R76/2006/r076-2006-cz1-2015-01.md`,
`ocr_md/R76/2006/r076-2006-de1-2014-02.md`). Both PDFs are on disk, so
both are re-runnable.

One file carries invalid UTF-8 bytes:
`ocr_md/R31/1995/r031-1995-ru1-2011-01.md` (invalid within its first
2,500 bytes; detected by byte-level validation, not visible in the
header fields).

Extraction difficulty: trivial — the headers parse as comments and
already agree with the register.

### O2. The issuing-authority block in the bodies — plane 03

The authority facts appear in the bodies under at least five distinct
presentations, measured across the 963 primary files:

1. Labeled key-value sections: `## Issuing authority` heading with
   `Name:` / `Address:` / `Notified body no.:` / `Person responsible:`
   lines — the style of
   `ocr_md/R105/1993/r105-1993-no1-2006-01.md:15-27`. An
   `Issuing authority`-style heading appears in 555 files; the literal
   line-start label `Issuing authority` (heading or inline) in 647.
2. The Member State line: `## OIML Member State The Netherlands` —
   637 files carry an `OIML Member State <country>` line, which states
   the authority's country without naming the body.
3. Glued single-line prose: `Issuing authority NMi Certin B.V. Person
   responsible: M.Ph.D. Schmidt`
   (`ocr_md/R117/2019/r117-2019-nl1-2021-06-rev3.md:33`), and the NMO
   letter style `Issuing authority: NMO` with
   `Person responsible: Max Linnemann - Head of Certification Body`
   (`ocr_md/R21/2007/r021-2007-gb1-2016-01.md:21-23`).
4. Glued single-line name+address:
   `Issuing authority Name: Office of OIML Affairs,General
   Administration of Quality Supervision, Inspection and Quarantine
   Address:N0.9 Madiandonglu,Haidian District,Beijing,100088P.R.China`
   (`ocr_md/R31/1995/r031-1995-cn1-2009-01.md:17` — note the missing
   space after `Address:` and the glued postal code).
5. No authority-designating heading at all: 394 of 963 files
   (concentrated in R76 84/183, R21 28/42, R31 26/39, R46 58/98,
   R51 60/100, R134 29/35); in these the authority facts live in
   letterhead prose, signature blocks
   (`ocr_md/R117/2019/r117-2019-nl1-2021-06-rev3.md:75`: `NMi Certin
   B.V., OIML Issuing Authority NL1`), or footer lines
   (`ocr_md/R21/2007/r021-2007-gb1-2016-01.md:51`).

`Person responsible:` appears in 522 files. `Address:` in 171; `Name:`
in 147.

**Notified body numbers: the evidence is nearly absent.** Across all
963 primary bodies, the phrase `Notified body` occurs in 4 files, of
which 3 are prose about EU directives, not facts about this
certificate's body; exactly one file carries a parsed notified-body
number: `Notified body no.: 0431` at
`ocr_md/R105/1993/r105-1993-no1-2006-01.md:25`. See Finding G3.

Extraction difficulty: the labeled style is table-driven; the glued and
absent-heading styles need model assistance to reach full coverage. The
extracted tier already covers the split — see Finding E3.

### O3. The applicant/manufacturer/holder blocks — plane 03

`## Applicant` heading: 211 files; inline `Applicant:` line: 52;
manufacturer-designated section (`## Manufacturer` or
`Manufacturer of the certified pattern/type`): 140. The NMO letter
style glues name and address into one string:
`Applicant: UCAST Pte Ltd 1091 Lower Delta Road #04-02 Singapore
169202` (`ocr_md/R21/2007/r021-2007-gb1-2016-01.md:25`), and
distinguishes the holder from the manufacturer in the document's own
words: `Manufacturer: The applicant`
(`ocr_md/R21/2007/r021-2007-gb1-2016-01.md:27`). The NL style keeps
them separate with distinct addresses (applicant in the UK,
manufacturer in the US,
`ocr_md/R117/2019/r117-2019-nl1-2021-06-rev3.md:35-47`).

The documents therefore make the holder/applicant/manufacturer
distinction plan 03 asks for, but the manifest's single `applicant`
field does not carry it.

Extraction difficulty: mixed — table-driven where the labeled style
holds, model assistance for the glued style.

### O4. The instrumental scope — plane 02

The Recommendation + instrument facts in the bodies:

- `Type:` line-start field: 180 files; `## Identification`-style
  heading: 116.
- Recommendation citation in the `R XXX:YYYY` form: 76 files (strongest
  in R117 37/85, R139 23/39); other documents cite the Recommendation
  as a heading (`## OIML R 21 - Edition 2007(E)`,
  `ocr_md/R21/2007/r021-2007-gb1-2016-01.md:33`) or bare fields
  (`R: 31` + `Edition: 1995`,
  `ocr_md/R31/1995/r031-1995-cn1-2009-01.md:39-41`). An `Edition:`
  line appears in 22 files.
- The instrument category rides the identification prose
  ("A fuel dispenser certified type",
  `ocr_md/R117/2019/r117-2019-nl1-2021-06-rev3.md:49`).

Extraction difficulty: needs model assistance for a uniform scope
record; the family-specific extracted tier already normalizes much of
it (`certified_type.category`, `type_designations`).

### O5. The accuracy class — plane 02, family-specific

An `Accuracy class`-bearing line (heading or labeled) appears in 307
of 963 primary files, concentrated by family: R46 87/98, R137 88/99,
R139 34/39, R117 71/85 — but R76 only 11/183, R51 13/100, R60 8/100.
Consistent with prior findings in this estate, R46/R76 render the
accuracy class as an inline image, and 904 of 963 files carry
`![](page=…,bbox=…)` image placeholders, so body-text coverage of the
accuracy class is structurally capped without vision extraction.

Extraction difficulty: table-driven where the line exists; needs model
(vision) assistance for the R46/R76 style.

### O6. The in-document revision history — plane 04

420 primary files carry a revision table (`<td>Revision</td>` marker),
and 201 carry the sentence `This revision replaces the previous
version.` The table form is
(Revision, Date, Description of the modification) — for example
`ocr_md/R117/2019/r117-2019-nl1-2021-06-rev3.md:413` (Initial
21 April 2021; rev 1 15 August 2023; rev 2 17 September 2025; rev 3
18 September 2025) and
`ocr_md/R76/2006/r76-2006-nl1-2021-09-rev1.md:144` (rev 0 2021-02-08;
rev 1 2023-10-31). These are document-stated dates, in two formats
(`21 April 2021` and `2021-02-08`).

This is the lifecycle evidence plan 04 can draw from the documents
themselves, independent of the register snapshots. See Finding G5.

Extraction difficulty: table-driven.

### O7. The scheme marker — plane 02

`This OIML Certificate is issued under scheme A` (or B): 620 files.
The manifest's era marker in `num` (`-A-`/`-B-`) is the same fact, and
the extracted tier carries it as `certificate.scheme` (880/880 filled).

Extraction difficulty: trivial.

## E — The extracted record tier (`pipeline-work/yaml/`, 880 records)

These are the per-certificate records the stats files measure, one per
md (except the 83 R76 md files without yaml). Each record carries a
`_meta` block and the sections `_common_certificate_schema.yaml` calls
for: `certificate`, `issuing_authority`, `applicants`,
`manufacturers`, `certified_type`, `characteristics`, `recommendation`,
`test_reports`, `revision_history`, `model_family`, `components`,
`footnotes`, and for 12 families `matrix_tables`.

### E1. `_meta` — planes 02 and 04

All 880 records carry `_meta.extraction_method: "glm-extract"` (880 of
880 — a third provenance vocabulary; see Finding G7). Missing fields
across all records: `source_pdf` absent in 3 (the no-PDF stubs);
everything else present in 880.

`_meta` vs manifest: `num` 880/880 known; `cert_id` 879/880 (the one
mismatch is Finding M5's content-resolved duplicate);
`status` 880/880; `issuing_year` 879/880 (Finding M6);
`applicant` 871/880 — the 9 differences are Finding M7's
document-vs-register name variants.

### E2. The certificate block — plane 02

`certificate.scheme`: 880/880; `certificate.member_state`: 879/880;
`certificate.date_issued`: 878/880; plus `number`, `project_number`,
`page_total`, `oiml_issuer_id`. The document-stated
`certificate.number` can disagree with the register num in the
edition-year segment:
`pipeline-work/yaml/R117/2019/r117-2019-nl1-2022-01.yaml` carries
`certificate.number: R117/2007-A-NL1-22.01` against
`_meta.num: R117/2019-A-NL1-22.01`. See Finding G1.

### E3. The organization sections — plane 03

- `issuing_authority` non-empty: 880/880 — name, `address_lines`,
  `person_responsible`, and frequently `phone`, `email`, `website`,
  `oiml_issuer_id`
  (sample: `pipeline-work/yaml/R117/2019/r117-2019-nl1-2022-01.yaml`,
  `issuing_authority.name: NMi Certin B.V.`, Thijsseweg 11, 2629 JA
  Delft, The Netherlands, `oiml_issuer_id: NL1`).
- `applicants` non-empty: 880/880 (name + `address_lines`).
- `manufacturers` non-empty: 854/880.
- `revision_history` non-empty: 594/880.

Plan 03's organizations dataset can therefore be derived from 880
complete per-certificate authority and party blocks today, with the
remaining 5,596 manifest rows awaiting extraction. The extracted tier
is where the authority facts are already normalized; the md tier is
the fallback for the 83 R76 files without yaml.

## S — The per-Recommendation schemas (`schema/`)

### S1. The family schemas agree on their skeleton — plane 02

All 22 `schema/R*.yaml` files share the same 13 top-level properties
(`certificate`, `issuing_authority`, `applicants`, `manufacturers`,
`certified_type`, `characteristics`, `recommendation`,
`test_reports`, `revision_history`, `model_family`, `components`,
`footnotes`, `d011_tests_applicable`) and the same 4 required keys
(`certificate`, `certified_type`, `characteristics`,
`recommendation`). They disagree in exactly two places:

1. `matrix_tables` is defined by 14 families (R46, R49, R50, R61,
   R85, R99, R105, R106, R107, R111, R129, R134, R136, R137) and
   absent from the other 8 (R21, R31, R51, R60, R76, R117, R126,
   R139).
2. The family-specific vocabulary inside `characteristics` and
   `recommendation.accuracy_classes` (for example R105's accuracy
   classes enum 0.3–2 at `schema/R105.yaml:62-82`).

The shared definitions live in `schema/_core.yaml` (357 lines:
`ScalarValue`/`RangeValue`/`ListValue`/`MapValue`, `StructuredValue`,
`Unit` with unitsml `unit_id`/`prefix`/`current_type`/`reference`,
`Certificate`, `IssuingAuthority`, `Party`/`PartyList`, `TestReport`
with its five-role enum, `RevisionEntry`/`RevisionHistory`,
`ModelVariant`/`ModelFamily`, `SoftwareIdentification`, `Component`,
`Footnote`, `MatrixTable`) and `schema/_modules/` (8 domain modules:
`accuracy.yaml`, `d011_environmental.yaml`, `flow_metering.yaml`,
`mechanical_speed.yaml`, `power_supply.yaml`, `software.yaml`,
`warmup_adjustment.yaml`, `weighing_capacity.yaml`), with unit
vocabularies in `_units.yaml` (672 lines) and `_units_local.yaml`.

These schemas are JSON Schema draft-07 documents. They are already the
"views over the canonical record" that plan 02 asks for — the audit
confirms the direction, and the canonical record should be built to
match them rather than the reverse.

### S2. The data contract file drifts from the data — planes 02 and 04

`schema/_common_certificate_schema.yaml` declares itself the canonical
structure every per-cert YAML conforms to. Three drift points:

1. It references `schema/vocabularies/R<NN>.yaml` in its header
   comment; no `schema/vocabularies/` directory exists (the
   vocabularies live in the `R*.yaml` files themselves).
2. Its `_meta.extraction_method` vocabulary is
   `"glm-ocr" | "glm-4.5v" | "error"`; the md tier observes
   `glm-ocr`/`pymupdf`/`fitz`/`error` and the yaml tier observes
   `glm-extract` (Findings O1, E1).
3. Its `_meta.status` vocabulary is
   `"Valid" | "Suspended" | "Withdrawn"`; the manifest observes only
   `Valid` and `Suspended` (Finding M3).

See Finding G7.

## T — The statistics (`stats/`)

All 22 `stats/R*.yaml` files share one shape: `recommendation`,
`sample_size` (equal to the family's yaml count), and a `summary` of
six counters (`certs_with_model_family`, `certs_with_components`,
`certs_with_matrix_tables`, `certs_with_footnotes`,
`total_model_variants`, `total_matrix_tables`), followed by
`type_level_characteristics` with per-attribute `fill_rate`,
`present_count`, and `by_unit` distributions including top values
(sample: `stats/R117.yaml`, `maximum_flow_rate` fill_rate 0.176,
present in 15 of 85, `by_unit` led by `L/min` 11).

What the stats already measure: extracted-characteristic fill rates
and unit distributions per family, on the extracted tier only.

What the planes programme should additionally measure, by the plan's
own lights: manifest-level coverage (fileName/local_path/download_status
rates per family), header-vs-manifest consistency counts (the audit's
Findings O1, E1 as a regression gate), authority-block extraction
success per family (the plan 03 coverage report), revision-table
capture rates (plan 04's document-stated evidence), and the
organization-variant resolution state (open questions count of plan
03's dataset).

## C — The signed-certificate consumer (`oimlsmart/cnml`)

The estate's signed-certificate stack consumes this repository's schema
stack today, and it already declares this repository authoritative. The
audit records the evidence here because the plans as written did not
carry this consumer, and because its two consumption mechanisms have
drifted from each other.

### C1. The canonical home is already declared — twice

`cnml/AGENTS.md` states: "The canonical OIML-CS certificate schemas and
the corpus of real certificate instances live in the OIML-CS
certificates repository… When schema fields or certificate shapes
disagree, the OIML-CS certificates repository is authoritative."
`cnml/CLAUDE.md`'s "Source of truth" section states the same: "Canonical
YAML schemas + 880 real cert instances: the OIML-CS certificates repo
(Ruby source-of-truth)". The `cnml-schemas` package README's "Source"
section states: "The canonical Ruby source-of-truth for these schemas
lives in the OIML-CS certificates repo. This package holds CNML-synced
copies."

### C2. Two consumption mechanisms, one of them drifted

cnml consumes the schemas two ways:

1. **Copied.** `cnml/packages/cnml-schemas/src/` holds copies of
   `_core.yaml`, `_units.yaml`, `_units_local.yaml`, the 8
   `_modules/*.yaml`, and the 22 `schemas/R*.yaml`, re-synced by a
   manual `cp` from `../../oiml-cs-certificates/schema/` (README,
   "Sync"). The copies carry a CNML-only extension set that this
   repository's files lack: an `EvaluationReportRef` definition in
   `_core.yaml`, an `evaluation_report` property in every R schema,
   and three metadata keys per schema (`x-oiml-category`,
   `x-oiml-short-title`, `x-oiml-cert-count`). A semantic YAML
   comparison of five sampled schemas (R105, R60, R76, R117, R137)
   finds exactly those four additions per schema and one in `_core`,
   with no other differences; the copies' most recent extension commit
   is `32c9a0e` ("TODO.ops/15 — the evaluation-report binding: the
   digest inside the signed payload"). The README's own sync
   instructions (a raw re-copy) would silently wipe this extension
   set.
2. **Direct.** `cnml/scripts/generate-types.ts` reads
   `../../oiml-cs-certificates/schema/*.yaml` live and generates
   `cnml-types` from this repository's files, with no copy involved.

The copy path and the direct read can therefore disagree with each
other inside cnml, and both disagree with this repository the moment
either side moves.

### C3. A corpus-derived fact is hardcoded in the consumer

The copies' `x-oiml-cert-count` values (42, 39, 98, 4, 5, 100, 100,
12, 100, 99, 2, 1, 3, 3, 1, 85, 9, 3, 35, 1, 99, 39) equal, family by
family, this repository's extracted-tier sample sizes (`stats/R*.yaml`
`sample_size`, Finding E1/S1's tier counts) as of the migration that
wrote them (`cnml/scripts/migrate-schema-metadata.ts`, a one-shot
script whose own header says "Run once after moving schemas into
schemas/ subdir… After running, delete this file"). The count is a
fact this repository owns, and it is already stale-by-design: the
extracted tier grows, the hardcoded number cannot. The same applies to
`x-oiml-category` and `x-oiml-short-title`, which are editorial labels
rather than corpus facts.

### C4. The signed envelope wraps the same record

The CNML format is a cryptographically signed envelope
(`packages/cnml-xml/`: XMLDSig, OpenTimestamps proofs, the
evaluation-report digest binding) around the certificate content model
this repository's schemas define; `cnml-xml/src/validate.ts:56`
validates the parsed certificate against "its per-R schema". The
per-instrument instance record
(`cnml-schemas/src/schemas/_instance.yaml`: `certificateId`,
`serialNumber`, `firmwareHash`, `manufacturingDate`,
`modelCertificateId`, `manufacturer`, `model`, `recommendationId`,
`calibrationData`) is the CNML-side Tier-5 record and is outside the
register's scope. cnml's round-trip samples are real records from this
repository's extracted tier: `cnml-schemas/src/samples/r60-sample.yaml`
carries `_meta.cert_id: 6922` and pairs with
`pipeline-work/yaml/R60/2021/r60-2021-nl1-2026-08-rev0.yaml` in this
repository.

## G — The findings that bend the plans

These are the gaps the plans assume away or the evidence contradicts.
Each states the finding, the evidence, and which plan it touches.

### G1. `num` is not yet the identity the contract says it is (02, 06)

Plan 06 states the manifest's `num` is the identity, "exactly and
immutably". The evidence: 23 nums sit on 2 rows each with conflicting
payloads (M5); num strings vary in form — R-prefix zero padding,
` Rev. N` / ` Annex. N` suffixes, `-A-`/`-B-` era markers, malformed
serials (M1); and the documents' own stated numbers can differ from
the register's num in the edition-year segment (E2). The canonical
record (02) needs an explicit identity rule — canonical num form,
revision as a field rather than a num suffix, and a stated precedence
between register num and document number — and the retrieval
contract's "exactly and immutably" needs to hold for the canonical
form, not the raw scrape's.

### G2. The corpus holds two name surfaces per organization (03)

The register's `applicant` spelling and the documents' stated name
differ in observed cases (M7, 9 of 880 records; plus the register's
own duplicate-row spelling drift, M5). Plan 03's normalization rules
should treat these as first-class variant evidence — rule-collapse
whitespace, punctuation, and legal-suffix variants; keep the
substantive ones (`Endress+Hauser SICK Engineering GmbH` vs
`Endress+Hauser SICK GmbH+Co. KG`) as distinct pending evidence, in
the dataset's open-questions section.

### G3. The notified-body fact family is nearly empty (03)

Plan 03 lists the notified body number as an organization fact. The
digitalized tier carries exactly one parsed notified-body number in
963 files (O2), and the extracted tier's `issuing_authority` carries
no notified-body field at all. The organizations dataset's
notified-body plane should be built as a schema slot with the
expectation that the corpus fills it sparsely — one attested value
today (`0431`, Justervesenet, `ocr_md/R105/1993/r105-1993-no1-2006-01.md:25`).

### G4. The status vocabulary is two states, not a lifecycle (04)

The register's observed value set is `Valid` (6,475) and `Suspended`
(1) — M3. The data contract anticipates `Withdrawn` (S2). Plan 04's
requirement that the vocabulary be "enumerated from the data, never
assumed" therefore yields: `{Valid, Suspended}` from the manifest,
plus the documents' own revision lifecycle (`Initial` + numbered
revisions, O6). The dataset should carry both, distinctly: the
register's status observations (snapshot-derived) and the documents'
revision timelines (evidence-derived).

### G5. Supersession evidence exists in the documents, barely in the register (04)

One manifest row embeds a supersession notice in `name` (M3, id 3191).
The documents carry 201 `This revision replaces the previous version.`
statements and 420 revision tables (O6), which supersede revisions
within a num, not nums across a family. Plan 04's rule that
supersession "never [be] inferred from year adjacency alone" holds;
the evidence base for num-level supersession links is today one row.
The protocol (snapshots + diffs) is indeed the load-bearing part, as
plan 04 itself states.

### G6. The register's year and the document's date are different facts (02, 04)

`issuingYear` carries one impossible value (2029, id 6683 — M2), one
contradicted value (2014 in the register vs 2013 in the document for
`R076/2006-GB1-2013.02` — M6), and 878 of 880 extracted records carry
a document-stated `certificate.date_issued` (E2) that the manifest
does not have at all. Plan 02's canonical record should carry both:
the register's `issuingYear` claim and the document's `date_issued`
evidence; plan 04's change records should observe them separately.

### G7. The provenance vocabulary has drifted across the tiers (02)

Three vocabularies for extraction provenance are live: the md headers
use `glm-ocr` / `pymupdf` / `fitz` / `error` (O1), the yaml records
use `glm-extract` (E1), and the data contract declares
`glm-ocr` / `glm-4.5v` / `error` (S2). Plan 02's canonical record
needs one enumerated vocabulary and a migration of the three current
spellings onto it; the pymupdf/fitz split is one method under two
names. The maintainer's decision of 2026-10-06 settles the model line:
glm-5.3-flash is the estate's model for both stages from here on
(better and cheaper than the glm-4.5v that produced the 880), and the
raw tiers (`ocr_raw/`, `extract_raw/`) record the model identity per
call so the two model generations stay distinguishable in the data.

### G8. The digitalized and extracted tiers cover a sixth of the corpus (02, 03)

963 of 6,476 certificates are digitalized (14.9%) and 880 are
extracted (13.6%) (tier table). Plan 03's coverage report should state
its denominators in these terms: organization facts are complete for
the 880 (E3: authority 880/880, applicants 880/880) and absent for the
other 5,596 rows until extraction extends. The 2 rate-limit error
stubs are re-runnable today (O1).

### G9. Where the plans' premises held (all plans)

The audit confirms, with evidence, the plans' load-bearing premises
that could have failed: the header block is 100% present and agrees
with the manifest on every comparable field (O1); the extracted tier's
organization sections are 100% filled (E3); the raw tier reconciles
exactly with the manifest (tier table); the schemas already share one
skeleton and one core-definition layer, so "views over the canonical
record" is the existing architecture, not a migration (S1); and the
statistics files measure exactly the tier plan 03 extends (T).

### G10. The canonical certificate record already exists and is already declared authoritative (02)

Plan 02 as written reads as if the canonical record must be defined; the
evidence says it is defined, and the estate has already named this
repository as its home (C1, C2). The plane's real work is governance of
the existing stack: versioning it, CI-validating the extracted tier
against it, adopting the CNML extension set into the canonical files so
the drifted copies can converge on one source, and replacing the two
informal consumption mechanisms (the manual re-copy and the
relative-path live read) with the release train's pinned checkouts.

### G11. A consumer hardcodes this repository's facts (00, 05)

`cnml-schemas`' copies hardcode per-family certificate counts that are
this repository's extracted-tier sample sizes at migration time (C3).
The planes' doctrine — consumers never re-derive a fact this repository
owns — extends to cnml: the counts and the label metadata either move
into the canonical schema files as maintained data or stop being
carried in the copies, and cnml's schema consumption joins the pins
discipline alongside the retrieval service and the certificates site.

## The plane mapping, in one table

| Fact family | Fields | Coverage | Difficulty | Plane |
| --- | --- | --- | --- | --- |
| Certificate identity | `manifest.id`, `manifest.num`, `ocr_md` header `cert_id`/`num`, `_meta.cert_id`/`num` | 100% / 100% / 100% of 963 / 100% of 880 | trivial (canonical-form rule needed per G1) | 02 |
| Register descriptive | `name`, `applicant`, `issuingYear` | 100% / 99.92% / 100% | trivial | 02 |
| File provenance | `fileName`, `local_path`, `download_status`, header `source_pdf` | 79.2% / 78.9% / 100% / 100% of 963 | trivial | 02 |
| Register status | `status`, `idStatus` | 100% | trivial | 02, 04 |
| Authority facts (body) | heading/label/member-state lines, `Person responsible`, `Name`, `Address` | 555–647 of 963 (per form); 522 person; 171 address | table-driven + model assistance | 03 |
| Authority facts (extracted) | `issuing_authority.*` | 880/880 | done (extend by extraction) | 03 |
| Holder/applicant facts (body) | `## Applicant`, inline `Applicant:`, manufacturer sections | 211 + 52 + 140 of 963 | table-driven + model assistance | 03 |
| Holder/applicant facts (extracted) | `applicants.*`, `manufacturers.*` | 880/880, 854/880 | done (extend by extraction) | 03 |
| Notified body | `Notified body no.` | 1 of 963 | needs model assistance; near-empty | 03 (G3) |
| Instrumental scope | `Type:`, `## Identification`, R-citations, `Edition:` | 180 / 116 / 76 / 22 of 963 | needs model assistance | 02 |
| Accuracy class | accuracy-class lines | 307 of 963; R76 11/183 (inline images) | table-driven + vision | 02 |
| Scheme | scheme line, `certificate.scheme` | 620 of 963; 880/880 | trivial | 02 |
| Document revision history | revision tables, replaces-previous line | 420 / 201 of 963; `revision_history` 594/880 | table-driven | 04 |
| Test report references | report prose/fields | 947 of 963 | table-driven | 02 |
| Organization name variants | manifest `applicant` vs document names | 9 of 880 differ | rule-driven normalization (G2) | 03 |
| Date evidence | `certificate.date_issued` | 878 of 880 | done | 02, 04 (G6) |
