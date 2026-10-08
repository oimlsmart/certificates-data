#!/usr/bin/env ruby
# frozen_string_literal: true

# The denominators report: the honest ledger of what the corpus holds and
# what each tier covers, computed from the tiers on disk. Every count is
# derived; nothing is hardcoded.

require "json"

REPO = File.expand_path("..", __dir__)

rows = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l) }
pdfs = Dir.glob("#{REPO}/certificates/R*/**/*.pdf").size
vision_raws = Dir.glob("#{REPO}/ocr_raw/R*/**/*.json").size
mds = Dir.glob("#{REPO}/ocr_md/R*/**/*.md").reject { |f| f =~ /backup/ }.size
records = Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").size
blocked_pages = Dir.glob("#{REPO}/ocr_raw/R*/**/*.json").count do |f|
  File.read(f).to_s.include?("blocked by provider content filter")
end
orgs = File.readlines("#{REPO}/datasets/organizations/organizations.jsonl").size rescue 0
history = File.readlines("#{REPO}/datasets/history/timelines.jsonl").size rescue 0
history_docs = File.readlines("#{REPO}/datasets/history/timelines.jsonl").count { |l| JSON.parse(l)["document"] } rescue 0

report = <<~REPORT
  # The denominators report
  # generated: #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}

  The register (manifest.jsonl)                       #{rows.size} rows
  Document-backed rows (local_path)                   #{rows.count { |r| r["local_path"] }}
  Distinct PDFs on disk                               #{pdfs}
  Register-only rows (no file ever existed)           #{rows.size - rows.count { |r| r["local_path"] }}

  Vision tier: raws committed                          #{vision_raws}
    + legacy md-era extractions                        #{mds - vision_raws > 0 ? mds - vision_raws : 0} (approx; md files without vision raws)
    filter-blocked certificates (page-level markers)   #{blocked_pages}

  Structured records (pipeline-work/yaml)             #{records}
    coverage of document-backed rows                   #{(records * 100.0 / [pdfs, 1].max).round(1)}%

  History dataset: rows                                #{history}
    rows with a joined document                        #{history_docs} (#{(history_docs * 100.0 / rows.size).round(1)}% of register)

  Organizations dataset: entities                      #{orgs}

  Completion arithmetic:
    #{rows.size} register rows
      = #{pdfs} document-backed  → vision-extracted via glm-5.3-flash + #{mds - vision_raws > 0 ? mds - vision_raws : 0} legacy
        → #{records} structured records today
      + #{rows.size - rows.count { |r| r['local_path'] }} register-only rows (name, applicant, year, status — no document exists)
REPORT

puts report
File.write("#{REPO}/datasets/DENOMINATORS.md", report)
puts "wrote datasets/DENOMINATORS.md"
