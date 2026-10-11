#!/usr/bin/env ruby
# frozen_string_literal: true
# Deterministic gap backfill for structured records: where the model left
# issuing_authority empty or certificate.member_state nil, parse them from
# the certificate's own markdown (the same evidence the history dataset
# reads). Every backfilled value carries "_backfill": "md-deterministic" so
# provenance stays explicit. No models.

require "yaml"
require "fileutils"

REPO = File.expand_path("..", __dir__)

def md_body(rel)
  p = "#{REPO}/ocr_md/#{rel}.md"
  File.exist?(p) ? File.binread(p).force_encoding("UTF-8").scrub : nil
end

def member_state(body)
  lines = body.each_line.map { |l| l.force_encoding("UTF-8").scrub }
  lines.each_with_index do |line, i|
    next unless line =~ /^\s*\#{0,6}\s*(?:\*\*)?\s*(?:oiml member state|member state of oiml)\b[:\s]*(.*)$/i
    value = $1.to_s.gsub("*", "").strip
    next if value =~ /^in which\b/i
    return value unless value.empty?
    follow = lines[(i + 1)..(i + 3)].to_a.map { |l| l.gsub("*", "").strip }.reject(&:empty?).first
    return follow if follow && follow.length <= 80 && follow !~ /important note|page=/i
  end
  nil
end

def authority_name(body)
  body.each_line do |l|
    m = l.match(/^\s*\#{0,6}\s*(?:\*\*)?\s*(?:issuing authority|certification board)\b[:\s]*(.*)$/i)
    next unless m
    v = m[1].gsub(/[*|]/, "").strip
    return v if v.size > 2 && v.size < 120 && v !~ /^(block|body|important)/i
  end
  nil
end

fixed_auth = 0
fixed_state = 0
skipped = 0
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  y = YAML.unsafe_load_file(f)
  rel = f.sub(%r{\A#{REPO}/pipeline-work/yaml/}, "").sub(/\.yaml\z/, "")
  body = md_body(rel)
  if body.nil?
    skipped += 1
    next
  end
  changed = false
  auth = (y["issuing_authority"] || {})
  if auth["name"].to_s.strip.empty?
    name = authority_name(body)
    if name
      y["issuing_authority"] = { "name" => name, "_backfill" => "md-deterministic" }
      fixed_auth += 1
      changed = true
    end
  end
  cert = (y["certificate"] || {})
  if cert["member_state"].to_s.strip.empty?
    ms = member_state(body)
    if ms
      cert["member_state"] = ms
      cert["_member_state_backfill"] = "md-deterministic"
      y["certificate"] = cert
      fixed_state += 1
      changed = true
    end
  end
  next unless changed
  File.write(f, y.to_yaml(line_width: 100).sub(/\A---\n/, ""))
end
puts "backfilled: #{fixed_auth} authority names · #{fixed_state} member states · #{skipped} without md"
