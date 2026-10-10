#!/usr/bin/env ruby
# frozen_string_literal: true
# Rebuild the 12 filter-blocked certificates' mds entirely from the PDFs'
# embedded text layers (born-digital documents; deterministic, no model).
# Prior mds kept as .chatnoise, prior raws as .pagemarkdownN, prior yamls as
# .staleN. Pages without a text layer keep their existing content.

REQUIRES = %w[json fileutils open3]
REQUIRES.each { |r| require r }

REPO = File.expand_path("..", __dir__)
stems = Dir.glob("#{REPO}/ocr_raw/R*/**/*.preunblock*").map { |f|
  f.sub(%r{\A#{REPO}/ocr_raw/}, "").sub(/\.json\.preunblock\d+\z/, "")
}.uniq

stems.each do |stem|
  pdf = "#{REPO}/certificates/#{stem}.pdf"
  md_path = "#{REPO}/ocr_md/#{stem}.md"
  raw_path = "#{REPO}/ocr_raw/#{stem}.json"
  yaml_path = "#{REPO}/pipeline-work/yaml/#{stem}.yaml"
  old_md = File.exist?(md_path) ? File.binread(md_path).force_encoding("UTF-8").scrub : nil
  header = old_md ? old_md[/\A(?:<!--.*?-->\s*\n?)+/m].to_s : ""

  page_count = `mutool info "#{pdf}" 2>/dev/null`.scan(/^Pages: (\d+)/).flatten.first.to_i
  page_count = 1 if page_count.zero?
  pages = (1..page_count).map do |p|
    txt, _e, _s = Open3.capture3("mutool", "draw", "-F", "text", pdf, p.to_s)
    txt = txt.strip.gsub(/\n{3,}/, "\n\n")
    txt.size >= 100 ? txt : "<!-- page #{p}: no text layer; content from prior extraction -->"
  end
  body = pages.join("\n\n---\n\n")

  if old_md
    File.rename(md_path, "#{md_path}.chatnoise#{Dir.glob("#{md_path}.chatnoise*").size + 1}")
  end
  File.write(md_path, "#{header}\n#{body}\n", mode: "w:UTF-8")
  if File.exist?(raw_path)
    File.rename(raw_path, "#{raw_path}.pagemarkdown#{Dir.glob("#{raw_path}.pagemarkdown*").size + 1}")
  end
  if File.exist?(yaml_path)
    File.rename(yaml_path, "#{yaml_path}.stale#{Dir.glob("#{yaml_path}.stale*").size + 1}")
  end
  covered = pages.count { |p| !p.start_with?("<!--") }
  puts "#{stem}: rebuilt from text layers (#{covered}/#{page_count} pages)"
end
