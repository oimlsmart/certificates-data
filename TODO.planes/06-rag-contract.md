# 06 — The retrieval service's consumption contract

What oimlsmart/ai expects from this repository, stated so the contract
survives personnel and refactors.

## The contract today (live, PR oimlsmart/ai#547)

- The declared checkout: `CERTIFICATES_REPO` points at this repository
  (the site's vendor symlink and the CI checkout both resolve it).
- The content pin: `ingest/certificates_pins.json` carries the repo, the
  ref, the manifest's SHA-256 prefix and the certificate count; the
  freshness gate fails loudly when the manifest's content moves off the
  pinned basis.
- The manifest's `num` is the identity: every certificate's chunk and
  register row keys on it, exactly and immutably.
- CI checks the gate against the pinned ref (public repo, sparse to the
  manifest).

## What this programme adds to the contract

- The canonical certificate schema (02) replaces the manifest's loose
  fields as the records' definition; the manifest stays as the raw
  scrape's provenance, never the contract's definition.
- The organizations dataset (03) becomes the authority facts' source —
  the retrieval service's authority provenance reads it, never re-parses
  the OCR bodies.
- The history dataset (04) becomes the status truth — the snapshot's
  status field becomes an observation, and the timeline answers the
  lifecycle questions.
- The release tag (05) is what the pins file pins.

## The laws the consumer holds itself to

- It never writes to this repository; its pins file is its own.
- Its projection (the D1 register table, the index chunks) is
  regenerable from a pinned checkout, and the freshness gate proves the
  regeneration is current.
- It states absence honestly: a fact this repository does not carry is
  answered as absent, never improvised.
