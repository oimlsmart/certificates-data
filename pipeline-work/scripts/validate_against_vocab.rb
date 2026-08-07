#!/usr/bin/env ruby
# frozen_string_literal: true
# Validate every cert YAML against its per-R schema.
#
# For each yaml/R<NN>/<edition>/<cert>.yaml:
#   1. Load schema/R<NN>.yaml
#   2. For each aspect in scope.aspects with an enum constraint, check the
#      cert's value(s) against the allowed set.
#   3. Collect violations and print a per-R summary + sample violations.

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"
SCHEMA_DIR = ROOT + "schema"

def load_r_schema(r_str)
  path = SCHEMA_DIR + "#{r_str}.yaml"
  return nil unless path.exist?
  YAML.load_file(path)
end

def values_to_array(v)
  return [] if v.nil?
  return [v] unless v.is_a?(Array)
  v
end

def validate_cert(yaml_path, schema)
  data = YAML.load_file(yaml_path)
  return [{ issue: "no_yaml_data" }] unless data.is_a?(Hash)

  r_str = yaml_path.parent.parent.basename.to_s
  chars = data.dig("characteristics", "type_level") || {}
  aspects = schema.dig("scope", "aspects") || {}

  violations = []
  aspects.each do |label, spec|
    next unless spec.is_a?(Hash)
    type = spec["type"]
    next unless %w[enum enum_multi].include?(type)
    allowed = spec["values"] || []
    next if allowed.empty?
    next unless chars.key?(label)

    value_obj = chars[label]
    next unless value_obj.is_a?(Hash)
    raw = value_obj["value"]
    vals = values_to_array(raw).map { |v| v.is_a?(Numeric) ? v.to_s : v.to_s.strip }
    bad = vals.reject { |v| allowed.include?(v) }
    next if bad.empty?
    violations << { label: label, bad: bad, allowed: allowed }
  end
  violations
end

# Walk every cert
puts "=== VALIDATION ==="
per_r = Hash.new { |h, k| h[k] = { total: 0, violations: 0, samples: [] } }
all_violations = []

Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
  r_str = yp.parent.parent.basename.to_s
  per_r[r_str][:total] += 1
  schema = load_r_schema(r_str)
  unless schema
    per_r[r_str][:violations] += 1
    per_r[r_str][:samples] << { cert: yp.basename.to_s, issue: "no_schema" }
    next
  end
  vs = validate_cert(yp, schema)
  next if vs.empty?
  per_r[r_str][:violations] += vs.size
  vs.first(2).each { |v| per_r[r_str][:samples] << { cert: yp.basename.to_s, **v } }
  all_violations.concat(vs.map { |v| { R: r_str, cert: yp.basename.to_s, **v } })
end

puts
puts "=== PER-R SUMMARY ==="
puts format("%-6s %8s %12s", "R", "certs", "violations")
per_r.keys.sort_by { |r| r[1..].to_i }.each do |r|
  v = per_r[r]
  flag = v[:violations].zero? ? "✓" : "✗"
  puts format("  %s %-4s %8d %12d", flag, r, v[:total], v[:violations])
end

puts
puts "=== SAMPLE VIOLATIONS (first 20) ==="
all_violations.first(20).each do |v|
  puts "  [#{v[:R]}] #{v[:cert]}"
  if v[:issue]
    puts "      issue: #{v[:issue]}"
  else
    puts "      #{v[:label]}: #{v[:bad].inspect} not in #{v[:allowed].inspect}"
  end
end

puts
puts "Total violations: #{all_violations.size}"

