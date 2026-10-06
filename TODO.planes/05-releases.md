# 05 — The consumers' pins

The consumers pin COMMIT SHAS — exactly the way the retrieval service's
certificates lane (PR oimlsmart/ai#547) and openapi plane already do
today: the pins file carries the repository, the revision SHA, and the
manifest's content hash, and the freshness gate fails loudly when the
content moves off that basis. Tags are optional ceremony for humans,
never a precondition for consumption — nothing in this programme waits
on a tag.

## The work

1. The pin update protocol: when this repository's datasets move, the
   consumer re-runs its plane build against the new revision and
   commits the refreshed pins in the same change as the re-index — the
   gate turns red the moment content moves under a pin, and green only
   with the deliberate bump.
2. The changelog: `RELEASE-NOTES.adoc` records what each pinned state
   moved (new certificates, schema versions, organization merges), in
   the estate's writing style — for the humans; the machines read the
   pins file.
3. The breakage rules: schema changes are additive while consumers hold
   the old pin (they cannot see a change until they bump); a breaking
   change lands together with a coordinated consumer bump, never
   silently.

## The definition of done

A consumer anywhere in the estate can state: "I am built from
certificates-data <SHA>" — and prove it from the freshness gate.
