#!/usr/bin/env ruby
# frozen_string_literal: true
# Normalize accuracy_class values across all cert YAMLs.
#
# Fixes:
#   1. Trailing ".0" stripped from numerics: "1.0" → "1"
#   2. Rejoin split decimals: ["0", "3"] → "0.3"
#   3. Filter values that don't belong to the R's accuracy system
#      (e.g. Roman "I" in numeric R117, "E2" environment class leaking in)
#   4. Wrap single values in lists (canonical form)
#
# Per-R system detection:
#   Roman (I/II/III/IIII)        — R50, R51, R61, R76, R106
#   Letter+digit (A, B, C, C3..) — R46, R60
#   Numeric (0.5, 1, 1.5, 2, 5)  — R31, R49, R85, R99, R105, R107, R111,
#                                   R117, R126, R129, R134, R136, R137, R139
#   Taximeter (R21)              — Numeric

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"
VOCAB_DIR = ROOT + "schema/vocabularies"

ROMAN_RS = %w[R50 R51 R61 R76 R106].freeze
LETTER_DIGIT_RS = %w[R46 R60].freeze
NUMERIC_RS = %w[R21 R31 R49 R85 R99 R105 R107 R111 R117 R126 R129 R134 R136 R137 R139].freeze

def system_for(r_str)
  return :roman if ROMAN_RS.include?(r_str)
  return :letter_digit if LETTER_DIGIT_RS.include?(r_str)
  return :numeric if NUMERIC_RS.include?(r_str)
  :unknown
end

def normalize_value(raw, system)
  return nil if raw.nil?
  s = raw.to_s.strip
  return nil if s.empty? || s.downcase == "none" || s.downcase == "n/a"

  # Strip trailing .0 from numeric (1.0 → 1, 2.0 → 2)
  if s.match?(/^\d+\.0+$/)
    s = s.sub(/\.0+$/, "")
  end

  # Per-system validation
  case system
  when :roman
    return s if s.match?(/^I{1,6}$/)
    # Coerce 1/11/111 → I/II/III
    return "I" * s.length if s.match?(/^1{1,6}$/)
    nil # filter non-roman values
  when :letter_digit
    return s if s.match?(/^[A-D]\d{0,1}$/)
    nil
  when :numeric
    return s if s.match?(/^\d+(\.\d+)?$/)
    nil # filter Roman leakage like "I", "II", "III"
  else
    s
  end
end

def rejoin_split_decimals(values)
  # Try to rejoin consecutive single-digit values into decimals.
  # ["0", "3"] → ["0.3"]; ["0", "3", "1", "0"] → ["0.3", "1.0"]
  # ["0", "3", "I"] → ["0.3", "I"]  (rejoin the digit pair, keep non-digit)
  return values unless values.is_a?(Array)
  return values unless values.any? { |v| v.to_s.match?(/^\d$/) }

  out = []
  i = 0
  while i < values.length
    a = values[i].to_s
    b = (i + 1 < values.length) ? values[i + 1].to_s : nil
    if a.match?(/^\d+$/) && b && b.match?(/^\d+$/)
      out << "#{a}.#{b}"
      i += 2
    else
      out << values[i]
      i += 1
    end
  end
  out
end

stats = Hash.new { |h, k| h[k] = { total: 0, fixed: 0, samples: [] } }

Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
  r_str = yp.parent.parent.basename.to_s
  stats[r_str][:total] += 1
  data = YAML.safe_load(yp.read, permitted_classes: [Symbol])
  next unless data.is_a?(Hash)

  chars = data.dig("characteristics", "type_level") || {}
  acc = chars["accuracy_class"]
  next unless acc.is_a?(Hash)

  raw = acc["value"]
  system = system_for(r_str)

  # Coerce to array for processing
  values = case raw
           when nil then []
           when Array then raw.map(&:to_s)
           else [raw.to_s]
           end

  # Step 1: rejoin split decimals
  values = rejoin_split_decimals(values)

  # Step 2: normalize each value per system
  cleaned = values.map { |v| normalize_value(v, system) }.compact

  # Dedupe preserving order
  seen = Set.new
  deduped = cleaned.select { |v| seen.add?(v) }

  new_raw = case deduped.size
            when 0 then nil
            when 1 then deduped.first
            else deduped
            end

  next if new_raw == raw
  stats[r_str][:fixed] += 1
  stats[r_str][:samples] << { cert: yp.basename("*.yaml").to_s, was: raw, now: new_raw }

  # Write back
  acc["value"] = new_raw
  acc["_normalized"] = true
  yp.write(YAML.dump(data))
end

puts "=== NORMALIZATION RESULTS ==="
puts format("%-6s %8s %8s", "R", "certs", "fixed")
stats.keys.sort_by { |r| r[1..].to_i }.each do |r|
  v = stats[r]
  puts format("  %-6s %8d %8d", r, v[:total], v[:fixed])
end

puts
puts "=== SAMPLES (first 15) ==="
all_samples = stats.values.flat_map { |v| v[:samples] }
all_samples.first(15).each do |s|
  puts "  #{s[:cert]}"
  puts "    was: #{s[:was].inspect}"
  puts "    now: #{s[:now].inspect}"
end

total_fixed = stats.values.sum { |v| v[:fixed] }
puts
puts "Total values normalized: #{total_fixed}"
