# 02 — The certificate record's formal schema

The certificate record becomes a formally validated dataset, not an
agreement between producers and consumers.

## The work

1. Define the canonical certificate record as a versioned schema
   (`schema/certificate/v1.json` or the equivalent typed-model source of
   truth, the estate's serialization laws applying — pydantic in the
   Python pipeline, never hand-rolled serializers). The record carries:
   the identity (num, cert_id), the organization references (issuer id,
   applicant id — pointers into the organizations dataset, not repeated
   strings), the register fields (status, issuingYear, idStatus), the
   extraction provenance (extraction_method, source_pdf), and the
   digitalized tier pointer.
2. Write the migration: today's manifest rows and OCR headers map to the
   canonical record mechanically; the mapping is documented field by
   field, including the renames (applicant ↔ holder) and the splits
   (the issuer code in the num vs the issuing-authority block in the
   body).
3. CI validates every record against the schema on every change; a
   record that fails validation blocks the merge, never ships as data.
4. The per-Recommendation schemas (`schema/R*.yaml`) become VIEWS over
   the canonical record (family-specific fields), not parallel truths.

## The consumer contract this establishes

The retrieval service's certificates lane reads the canonical records;
its wire metadata (cert_holder / cert_model / cert_status) becomes a
projection of the schema, and its pins file (ingest/certificates_pins.json
in oimlsmart/ai) pins this repository's release.
