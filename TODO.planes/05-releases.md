# 05 — The release train

The datasets version the way the model library does: git tags are the
releases, consumers pin them, and nothing consumes main.

## The work

1. The tag semantics: `data-vN` tags mark validated dataset states
   (certificates + organizations + history move together — one domain,
   one version line). CI validates every dataset against its schema and
   only then is the tag cut, by the maintainer, never by automation.
2. The changelog: `RELEASE-NOTES.adoc` records what each release moved
   (new certificates, schema versions, organization merges), in the
   estate's writing style.
3. The consumers' pins: the certificates site's build pins the tag in
   its vendor checkout; the retrieval service's
   `ingest/certificates_pins.json` carries the tag and the manifest
   hash, and its CI checks the gate against the pinned ref — the pins
   discipline is already live there (PR oimlsmart/ai#547); this task
   moves the pin from the bootstrap SHA to the first `data-v1` tag.
   cnml joins the same discipline: its cnml-types generation stops
   reading this repository through a relative path, its cnml-schemas
   copies re-sync from the pinned tag rather than a manual `cp`, and
   the corpus facts its copies hardcode (audit C3) are refreshed from
   the release or dropped.
4. The breakage rules: schema changes are additive within a tag line;
   a breaking change cuts a new major line and the consumers migrate
   visibly, never silently.

## The definition of done

A consumer anywhere in the estate can state: "I am built from
certificates-data data-vN" — and prove it from the freshness gate.
