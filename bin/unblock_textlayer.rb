#!/usr/bin/env ruby
# frozen_string_literal: true

# Text-layer recovery for provider-filtered pages: the certificate's own
# embedded PDF text needs no model and no filter. Recovered text replaces the
# blocked marker in the raw (prior kept as .preunblock) and in the md. Scanned
# pages without text layers stay honestly blocked.

require "json"
require "open3"

REPO = File.expand_path("..", __dir__)

recovered = 0
stayed = 0
Dir.glob("#{REPO}/ocr_raw/R*/**/*.json").each do |raw_path|
  next unless File.read(raw_path).include?("blocked by provider content filter")
  raw = JSON.parse(File.read(raw_path))
  pp_detail = raw["per_page"] or next
  content = raw.dig("choices", 0, "message", "content")
  stem = raw_path.delete_prefix("#{REPO}/ocr_raw/").delete_suffix(".json")
  pdf = "#{REPO}/certificates/#{stem}.pdf"
  changed = false
  pp_detail.each_with_index do |entry, i|
    next unless entry["status"] == "blocked"
    page = entry["page"]
    txt, _err, _st = Open3.capture3("mutool", "draw", "-F", "text", pdf, page.to_s)
    txt = txt.strip.gsub(/\n{3,}/, "\n\n")
    next if txt.size < 200
    marker = "<!-- page #{page}: blocked by provider content filter; transcription unavailable -->"
    next unless content&.include?(marker)
    File.rename(raw_path, "#{raw_path}.preunblock#{Dir.glob("#{raw_path}.preunblock*").size + 1}")
    content = content.sub(marker, "<!-- page #{page}: recovered from the PDF's embedded text layer (deterministic, no model) -->\n\n#{txt}")
    pp_detail[i] = { "page" => page, "status" => "recovered", "strategy" => "pdf-text-layer" }
    changed = true
    recovered += 1
    puts "RECOVERED #{stem} p#{page} (#{txt.size}c from text layer)"
  end
  next unless changed
  raw["choices"][0]["message"]["content"] = content
  raw["per_page"] = pp_detail
  File.write(raw_path, JSON.pretty_generate(raw))
  md_path = "#{REPO}/ocr_md/#{stem}.md"
  if File.exist?(md_path)
    md = File.binread(md_path).force_encoding("UTF-8").scrub
    pp_detail.each do |e|
      next unless e["status"] == "recovered"
      md = md.sub("<!-- page #{e['page']}: blocked by provider content filter; transcription unavailable -->",
                  "<!-- page #{e['page']}: recovered from the PDF's embedded text layer -->")
    end
    File.write(md_path, md, mode: "w:UTF-8")
  end
  # the page-level raw is markdown-shaped; set it aside so the split extractor
  # builds a proper record raw from the recovered document
  File.rename(raw_path, "#{raw_path}.pagemarkdown")
  stale_yaml = "#{REPO}/pipeline-work/yaml/#{stem}.yaml"
  File.rename(stale_yaml, "#{stale_yaml}.stale#{Dir.glob("#{stale_yaml}.stale*").size + 1}") if File.exist?(stale_yaml)
end
puts "text-layer recovered: #{recovered} pages; stayed blocked: #{stayed}"
