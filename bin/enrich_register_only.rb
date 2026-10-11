#!/usr/bin/env ruby
# frozen_string_literal: true
# Deterministic enrichment for register-only rows (no document ever existed):
# parse the type/model designations the register's name string embeds. The
# output is a separate dataset — the register row itself is never mutated.

require "json"

REPO = File.expand_path("..", __dir__)

enriched = 0
out = File.open("#{REPO}/datasets/certificates/register-only-enrichment.jsonl", "w:UTF-8")
File.readlines("#{REPO}/manifest.jsonl").each do |l|
  r = JSON.parse(l)
  next if r["local_path"]
  name = r["name"].to_s
  types = []
  name.scan(/\b(?:Type|Typ|Mod(?:el|èle|èle)?|Model designation)[:\s]+([^,;()\n]{1,80})/i) { types << Regexp.last_match(1).strip }
  types = types.reject(&:empty?).flat_map { |t| t.split(/\s*(?:,|\/|\bor\b)\s*/i) }.reject { |t| t.size > 60 || t.size < 1 }.uniq
  instrument = name.split(/\s*[-–—]\s*(?:Type|Mod|Model)/i).first.to_s.strip
  instrument = nil if instrument.empty? || instrument.size < 3
  rec = { "cert_id" => r["id"], "num" => r["num"], "instrument_category" => instrument,
          "type_designations" => types, "source" => "register name string (deterministic parse)" }
  out.puts(JSON.generate(rec))
  enriched += 1 if !types.empty? || instrument
end
out.close
puts "register-only rows: enriched #{enriched}"
