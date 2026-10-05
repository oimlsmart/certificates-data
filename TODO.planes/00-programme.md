# 00 — The planes programme

## The mission

This repository graduates from "the certificates corpus" to the OIML-CS
domain's single source of truth: every plane the platform and the
retrieval service consume comes from here, as a validated, versioned,
tagged dataset. The site (oimlsmart/certificates) and the retrieval
service (oimlsmart/ai) are both consumers; neither owns a fact.

The doctrine is the ecosystem's own: one data-owning repository per
domain; consumers pin releases; every fact is schema-validated at
commit time; every derived store is regenerable from the datasets.

## The planes

1. **Certificates** (exists) — the register manifest, the digitalized
   tier, the per-Recommendation schemas. Formalized in 02.
2. **Organizations** (to build, 03) — issuing authorities, notified
   bodies, applicants/holders: the institutional facts the register's
   own documents carry, extracted and normalized.
3. **History** (to build, 04) — the status timelines: issuance,
   withdrawal, supersession, captured as successive register snapshots
   diff into change records instead of overwriting.

## The laws

- Consumers never scrape a site build and never re-derive a fact this
  repository owns.
- Every dataset carries a schema; CI validates the dataset against the
  schema on every change.
- Releases are git tags; a consumer pins a tag and the freshness gate
  compares its basis against it.
- The raw PDF tier stays in this repository (heavy, sparse-checked-out);
  derived stores everywhere else are regenerable without it.
