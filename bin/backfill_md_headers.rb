#!/usr/bin/env ruby
# frozen_string_literal: true

# Add the estate's 6 manifest-derived header fields to glm-5.3-flash md
# files that were written without them. Idempotent; touches only files
# whose header block carries extraction_method: glm-5.3-flash and no cert_id.

require "json"

REPO = File.expand_path("..", __dir__)

manifest_by_path = {}
File.foreach("#{REPO}/manifest.jsonl") do |line|
  row = JSON.parse(line)
  manifest_by_path[row["local_path"]] ||= row if row["local_path"]
end

filled = 0
skipped = 0
no_row = []

Dir.glob("#{REPO}/ocr_md/R*/**/*.md").sort.each do |md|
  text = File.binread(md).force_encoding("UTF-8").scrub
  next unless text.include?("<!-- extraction_method: glm-5.3-flash -->")
  next if text.include?("<!-- cert_id:")
  source_pdf = text[/<!-- source_pdf:\s*(.*?)\s*-->/, 1]
  row = source_pdf && manifest_by_path[source_pdf]
  unless row
    no_row << md
    next
  end
  num = row["num"].to_s
  issuer = num[/\AR0?\d+\/\d{4}-([A-Z]{2}\d+)-/, 1] || num[/\AR0?\d+\/\d{4}-[A-Z]-([A-Z]{2}\d+)-/, 1]
  header = <<~HEADER
    <!-- cert_id: #{row["id"]} -->
    <!-- num: #{num} -->
    <!-- applicant: #{row["applicant"]} -->
    <!-- issuing_year: #{row["issuingYear"]} -->
    <!-- status: #{row["status"]} -->
    <!-- issuer: #{issuer} -->
  HEADER
  text = text.sub("<!-- extraction_method: glm-5.3-flash -->", header + "<!-- extraction_method: glm-5.3-flash -->")
  File.write(md, text, mode: "w:UTF-8")
  filled += 1
end

puts "filled: #{filled}; already complete: skipped (not counted); without manifest row: #{no_row.size}"
no_row.first(5).each { |f| puts "  no row: #{f}" }
