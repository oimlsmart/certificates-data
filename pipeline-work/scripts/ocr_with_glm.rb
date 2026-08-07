#!/usr/bin/env ruby
# frozen_string_literal: true
# OCR all selected R76/2006 certs via GLM-OCR (z.ai layout_parsing API).
#
# Uses the shared GlmOcr library from ../resolutions-data/scripts/ocr/glm_ocr.rb.
# Writes markdown to ocr_md/R76/2006/<stem>.md (GLM-OCR layout-parsed, not pymupdf).
#
# Usage:
#   ruby ocr_pipeline/ocr_with_glm.rb             # all 100
#   ruby ocr_pipeline/ocr_with_glm.rb --limit 3   # smoke test
#   ruby ocr_pipeline/ocr_with_glm.rb --only r076-2006-bg1-2013-17-rev1

require "json"
require "pathname"
require "fileutils"
require "shellwords"

REPO_ROOT   = Pathname.new(File.expand_path("..", __dir__))
GLM_LIB     = REPO_ROOT.parent + "resolutions-data/scripts/ocr/glm_ocr.rb"
SELECTION   = REPO_ROOT + "ocr_pipeline/selection.jsonl"
OUT_DIR     = REPO_ROOT + "ocr_md/R76/2006"
MD_PREVIOUS = OUT_DIR.dup # where pymupdf output lives; we'll overwrite with GLM output
PREV_BACKUP = REPO_ROOT + "ocr_md/R76/2006-pymupdf-backup"

abort "GLM lib not found at #{GLM_LIB}" unless GLM_LIB.exist?
require_relative GLM_LIB.to_s

# Pick a per-project cache so we don't pollute resolutions-data's cache,
# but still benefit from caching across re-runs.
project_cache = REPO_ROOT + "_glm_ocr_cache"
FileUtils.mkdir_p(project_cache)
ResolutionsData::GlmOcr.const_set(:CACHE_DIR, project_cache.to_s)

limit = nil
only  = nil
ARGV.each do |arg|
  case arg
  when /\A--limit=(\d+)\z/ then limit = $1.to_i
  when /\A--limit\z/       then nil # value form
  when /\A--only=(.+)\z/   then only = $1
  when /\A--only\z/        then nil
  end
end

# Move existing pymupdf .md files aside first (only once)
if !PREV_BACKUP.exist? && OUT_DIR.exist? && Dir.children(OUT_DIR).any?
  FileUtils.mv(OUT_DIR, PREV_BACKUP)
  FileUtils.mkdir_p(OUT_DIR)
  warn "Moved previous pymupdf output to #{PREV_BACKUP.basename}"
end

FileUtils.mkdir_p(OUT_DIR)
rows = SELECTION.readlines.map { |l| JSON.parse(l) }
rows = rows.select { |r| r["local_path"].end_with?("#{only}.pdf") } if only
rows = rows.first(limit) if limit
puts "OCR #{rows.size} certs via GLM-OCR (cache: #{project_cache})"

ocr = ResolutionsData::GlmOcr.new
counts = { ok: 0, error: 0, skipped: 0 }
rows.each_with_index do |r, i|
  stem = File.basename(r["fileName"], ".pdf")
  out  = OUT_DIR + "#{stem}.md"
  if out.exist? && out.size > 0
    counts[:skipped] += 1
    warn "  [#{i + 1}/#{rows.size}] skip #{stem} (exists)"
    next
  end

  pdf = REPO_ROOT + r["local_path"]
  num_pages = `pdfinfo #{pdf.to_s.shellescape} 2>/dev/null`[/^Pages:\s+(\d+)/, 1]&.to_i || 1

  header = [
    "<!-- cert_id: #{r['id']} -->",
    "<!-- num: #{r['num']} -->",
    "<!-- applicant: #{r['applicant']} -->",
    "<!-- issuing_year: #{r['issuingYear']} -->",
    "<!-- status: #{r['status']} -->",
    "<!-- issuer: #{r['issuer']} -->",
    "<!-- extraction_method: glm-ocr -->",
    "<!-- source_pdf: #{r['local_path']} -->",
    "",
    "# #{r['num']}",
    "",
  ].join("\n")

  begin
    md = ocr.ocr_pdf(pdf.to_s, num_pages: num_pages)
    out.write(header + "\n" + md + "\n")
    counts[:ok] += 1
    warn "  [#{i + 1}/#{rows.size}] ok   #{stem} (#{md.size} chars)"
  rescue => e
    warn "  [#{i + 1}/#{rows.size}] FAIL #{stem}: #{e.message[0, 200]}"
    counts[:error] += 1
    out.write(header + "\n<!-- OCR ERROR: #{e.message[0, 500]} -->\n")
  end
end

puts "Done. #{counts}"
