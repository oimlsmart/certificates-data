#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate the _meta block of structured records whose md headers were
# backfilled after the record was written. Reads each record's existing raw
# (no model calls), rebuilds the yaml with the complete headers, and rewrites
# the file in place. Records with a populated _meta.num are untouched.

require "json"
require "yaml"

REPO = File.expand_path("..", __dir__)
SECTIONS = %w[certificate issuing_authority applicants manufacturers certified_type
              characteristics recommendation test_reports revision_history
              model_family components footnotes matrix_tables]

def md_header(path)
  raw = File.binread(path).force_encoding("UTF-8").scrub
  header = {}
  block = raw[/\A(?:<!--.*?-->\s*\n?)+/m].to_s
  block.scan(/<!--\s*(\w+):\s*(.*?)\s*-->/m) { |k, v| header[k] = v }
  header
end

def content_of(parsed_response)
  v4 = parsed_response.dig("choices", 0, "message", "content")
  return v4 if v4.is_a?(String) && !v4.empty?
  blocks = parsed_response["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

def parse_model_json(text)
  s = text.to_s.strip
  s = s.sub(/\A```(?:json)?\s*\n/m, "").sub(/\n```\s*\z/m, "")
  begin
    JSON.parse(s)
  rescue JSON::ParserError
    repaired = s.gsub(/,\s*([\]}])/, '\1')
    begin
      JSON.parse(repaired)
    rescue JSON::ParserError
      m = s.match(/\{.*\}/m)
      m ? JSON.parse(m[0]) : nil
    rescue JSON::ParserError
      nil
    end
  end
end

def build_yaml(header, parsed)
  num = header["num"].to_s
  ordered = { "_meta" => {
    "cert_id" => header["cert_id"]&.to_i,
    "num" => num,
    "applicant" => header["applicant"],
    "issuing_year" => header["issuing_year"],
    "status" => header["status"],
    "issuer" => header["issuer"],
    "recommendation" => num[/\AR0?(\d+)\//] ? "R#{$1}" : nil,
    "edition_year" => num[/\AR0?\d+\/(\d{4})-/, 1]&.to_i,
    "extraction_method" => "glm-extract",
    "source_pdf" => header["source_pdf"],
  } }
  SECTIONS.each { |k| ordered[k] = parsed[k] if parsed.key?(k) }
  (parsed.keys - SECTIONS - %w[_meta]).each { |k| ordered[k] = parsed[k] }
  ordered.to_yaml(line_width: 100).sub(/\A---\n/, "")
end

fixed = 0
skipped = 0
no_raw = []
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |yaml_path|
  rel = yaml_path.delete_prefix("#{REPO}/pipeline-work/yaml/").delete_suffix(".yaml")
  y = YAML.unsafe_load_file(yaml_path)
  next unless y.dig("_meta", "num").to_s.empty?
  raw_path = "#{REPO}/extract_raw/#{rel}.json"
  unless File.exist?(raw_path)
    no_raw << rel
    next
  end
  header = md_header("#{REPO}/ocr_md/#{rel}.md")
  parsed = parse_model_json(content_of(JSON.parse(File.read(raw_path))))
  if parsed.nil? || !parsed.is_a?(Hash)
    no_raw << "#{rel} (unparseable raw)"
    next
  end
  File.write(yaml_path, build_yaml(header, parsed), mode: "w:UTF-8")
  fixed += 1
end

puts "regenerated _meta: #{fixed}; no raw / unusable: #{no_raw.size}"
no_raw.first(8).each { |r| puts "  #{r}" }
