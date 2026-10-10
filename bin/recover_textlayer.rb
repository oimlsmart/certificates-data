#!/usr/bin/env ruby
# frozen_string_literal: true
# Definitive text-layer recovery for every raw that still carries a blocked
# page marker. For each blocked page: extract the PDF's embedded text via
# mutool (deterministic, no model, no filter); if substantial, replace the
# marker in raw and md (prior kept as .preunblockN), mark the per_page entry
# recovered, and set the record's yaml aside as .staleN so the split extractor
# rebuilds it from the recovered document. Scanned pages stay honestly blocked.

require "json"
require "open3"

REPO = File.expand_path("..", __dir__)
report = []

Dir.glob("#{REPO}/ocr_raw/R*/**/*.json").sort.each do |raw_path|
  next if raw_path =~ /\.(broken|attempt|preunblock|pagemarkdown|part)/
  txt = File.read(raw_path)
  next unless txt.include?("blocked by provider content filter")
  raw = JSON.parse(txt)
  pp_detail = Array(raw["per_page"])
  stem = raw_path.delete_prefix("#{REPO}/ocr_raw/").delete_suffix(".json")
  pdf = "#{REPO}/certificates/#{stem}.pdf"
  content = raw.dig("choices", 0, "message", "content").to_s
  changed = false
  pp_detail.each_with_index do |entry, i|
    next unless entry["status"] == "blocked"
    page = entry["page"]
    page_text, _e, _s = Open3.capture3("mutool", "draw", "-F", "text", pdf, page.to_s)
    page_text = page_text.strip.gsub(/\n{3,}/, "\n\n")
    marker = "<!-- page #{page}: blocked by provider content filter; transcription unavailable -->"
    if page_text.size >= 200 && content.include?(marker)
      aside = "#{raw_path}.preunblock#{Dir.glob("#{raw_path}.preunblock*").size + 1}"
      File.rename(raw_path, aside)
      content = content.sub(marker,
        "<!-- page #{page}: recovered from the PDF's embedded text layer (deterministic, no model) -->\n\n#{page_text}")
      pp_detail[i] = { "page" => page, "status" => "recovered", "strategy" => "pdf-text-layer" }
      changed = true
      report << "RECOVERED #{stem} p#{page}: #{page_text.size}c -> #{aside.sub(%r{\A#{REPO}/}, "")}"
    else
      report << "STILL BLOCKED #{stem} p#{page}: text layer #{page_text.size}c (scan or too short)"
    end
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
  stale_yaml = "#{REPO}/pipeline-work/yaml/#{stem}.yaml"
  if File.exist?(stale_yaml)
    File.rename(stale_yaml, "#{stale_yaml}.stale#{Dir.glob("#{stale_yaml}.stale*").size + 1}")
    report << "YAML SET ASIDE: #{stale_yaml.sub(%r{\A#{REPO}/pipeline-work/yaml/}, "")}.stale*"
  end
end
File.write("#{REPO}/datasets/_recovery_report.txt", report.join("\n") + "\n")
puts report.join("\n")
