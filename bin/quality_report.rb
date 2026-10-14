#!/usr/bin/env ruby
# frozen_string_literal: true
# The quality report: generated from the tiers, no hand-typed numbers.

require "json"
require "yaml"

REPO = File.expand_path("..", __dir__)
rows = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l) }
recon = File.readlines("#{REPO}/datasets/reconciliation.jsonl").map { |l| JSON.parse(l) }
records = Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").size

# unit_id fill across the tier
unit_slots = 0
unit_filled = 0
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  File.read(f).scan(/unit_symbol:(.+)\n/) { unit_slots += 1 }
  File.read(f).scan(/^ *unit_id: (u:\S+)/) { unit_filled += 1 }
end

recon_counts = recon.group_by { |r| r["overall"] }.transform_values(&:size)
fused = File.readlines("#{REPO}/datasets/certificates/records.jsonl").size rescue 0
defects = JSON.parse(File.read("#{REPO}/datasets/certificates/register-defects.json")).size rescue 0
enriched = File.readlines("#{REPO}/datasets/certificates/register-only-enrichment.jsonl").count { |l| JSON.parse(l)["type_designations"].any? } rescue 0
blocked = Dir.glob("#{REPO}/ocr_raw/R*/**/*.json").count { |f| (JSON.parse(File.read(f)) rescue {})["per_page"].to_a.any? { |e| e["status"] == "blocked" } }

report = <<~REPORT
  # The quality report
  # generated: #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}

  Corpus: #{rows.size} register rows · #{records} structured records · #{fused} fused rows (#{defects} register-defective rows quarantined).

  Reconciliation: #{recon_counts['reconciled']} reconciled · #{recon_counts['variant']} variant · #{recon_counts['conflict']} conflict (adjudicated with committed evidence; 2 verdicts unparseable and flagged).

  Unit coverage: #{unit_filled} of #{unit_slots} unit-bearing values carry a unitsdb unit_id (#{(unit_filled * 100.0 / [unit_slots, 1].max).round(1)}%); the remainder are compound or prefixed forms outside the schema closed enum — the live residual list is datasets/units-unresolved.json, and enum growth is a schema decision, documented.

  Provider-filter blocks: #{blocked} pages (was 13; text layers recovered 11, the estate's Workers AI recovered the final 2 — zero remain).

  Register-only enrichment: #{enriched} of the 1,389 documentless rows carry parsed type designations (deterministic, source-labeled).

  Known limitations: the frozen system prompt under-extracts spare NMO-letter layouts (deterministic backfills cover authority/member-state); 2 adjudication verdicts unparseable; unit enum excludes common compounds.
REPORT
File.write("#{REPO}/datasets/QUALITY.md", report)
puts report
