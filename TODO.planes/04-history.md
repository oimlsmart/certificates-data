# 04 — The history dataset

The register is a snapshot; the domain's truth is a timeline. Successive
scrapes diff into change records instead of overwriting, and the
certificate's lifecycle becomes first-class data: issued, withdrawn,
suspended, superseded, reinstated — with the dates the register states
and the observation dates of every change this repository captures.

## The work

1. The change-capture protocol: every scrape stores its snapshot under
   `snapshots/YYYYMMDD/manifest.jsonl` (content-addressed, compressed);
   a new snapshot diffs against the previous one into
   `datasets/history/changes.jsonl` — one record per field-level change
   (num, field, from, to, observed_at, snapshot pair).
2. The lifecycle record: per certificate num, the ordered timeline built
   from the change records; status transitions validated against the
   register's own state vocabulary (the idStatus / status fields' value
   set, enumerated from the data, never assumed).
3. The bootstrap problem, stated and solved: today's corpus holds ONE
   snapshot, so the timeline begins empty and fills as scrapes
   accumulate — the protocol matters more than the initial data. The
   scrape cadence lands in CI (a scheduled workflow running the
   existing downloader, committing the snapshot + the diff).
4. Supersession links between certificate nums (a successor certificate
   replacing a withdrawn one within a family) ride the same change
   records — never inferred from year adjacency alone; the register's
   own fields and the documents' stated references are the evidence.

## The consumers

The retrieval service answers "is X still certified and what happened
to it" from the timeline, not from a snapshot's status field alone; the
certificates site renders the lifecycle.
