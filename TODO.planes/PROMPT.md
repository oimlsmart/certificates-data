# The starting prompt

You are working in oimlsmart/certificates-data, the OIML-CS domain's
single source of truth: the certificate register's scrape manifest, the
digitalized tier, the per-Recommendation schemas, and the Python
pipeline that built them. Your programme is TODO.planes/ — read
00-programme.md first, then every numbered file in order. The mission:
this repository graduates from "the certificates corpus" to the domain's
data home, and every plane the certificates site and the retrieval
service (oimlsmart/ai) consume comes from here as a validated, versioned,
tagged dataset.

The order of work is the numbering: the audit (01) is evidence-gathering
and gates everything after it — do not design a schema before the census
tells you what the corpus actually carries. The certificate schema (02)
and the organizations dataset (03) are independent of each other once
the audit lands; the history dataset (04) is protocol-first and can
start immediately. The release train (05) and the retrieval contract
(06) land last, because they formalize what the earlier files built.

The laws you operate under, all of them hard:

- Never delete a source file, in this repository or anywhere in the
  estate. Extraction adds; it never removes.
- All changes go through pull requests; never commit to main, never
  push tags. Tags are releases and the maintainer cuts them.
- The datasets carry schemas and CI validates them; data that fails
  validation blocks the merge instead of shipping.
- No hand-rolled serialization: the Python pipeline uses its framework's
  serializers (pydantic models for the records), the same law the whole
  estate codes under.
- The consumer's law is your boundary: oimlsmart/ai never writes here,
  and its contract file (TODO.planes/06-rag-contract.md) is binding on
  what you may change without a coordinated bump.
- Write in the estate's style: complete sentences, stated subjects, no
  fragments, no invented labels. Every claim in the audit cites a file
  and a field.

When the audit (01) lands, stop and reconcile its findings against the
numbered plans before building: the plans describe what to build, but
the audit's evidence decides in what detail. Flag every gap you find in
the corpus (fields the plans assume and the data does not carry) in the
audit findings, and let the plans bend to the evidence.
