#!/usr/bin/env ruby
# frozen_string_literal: true
# TypeValidator: validates cert characteristic values against declared types.
#
# Fully data-driven: reads type specs from schema/_modules/*.yaml and
# schema/R<NN>.yaml. Implements checkers for every declared type:
#   enum, enum_multi, numeric, range, string, compound, boolean
#
# Usage:
#   validator = TypeValidator.new(schema_dir: Pathname.new("schema"))
#   violations = validator.validate_cert(yaml_path)
#

require "yaml"
require "pathname"

module OimlCs
  class TypeValidator
  def initialize(schema_dir:)
    @schema_dir = schema_dir
    @modules_dir = schema_dir + "_modules"
    load_modules
  end

  def validate_cert(yaml_path)
    data = YAML.load_file(yaml_path)
    return [{ issue: "no_yaml_data" }] unless data.is_a?(Hash)

    r_str = yaml_path.parent.parent.basename.to_s
    schema = load_r_schema(r_str)
    return [{ issue: "no_r_schema", r: r_str }] unless schema

    chars = data.dig("characteristics", "type_level") || {}
    aspects = schema.dig("scope", "aspects") || {}
    r_specific = schema["r_specific_aspects"] || {}

    violations = []

    # Check module-inherited aspects + R-specific aspects
    all_specs = {}
    aspects.each { |label, spec| all_specs[label] = resolve_spec(label, spec) }
    r_specific.each { |label, spec| all_specs[label] = spec }

    all_specs.each do |label, spec|
      next unless spec && spec["type"]
      next unless chars.key?(label)
      value_obj = chars[label]
      next unless value_obj.is_a?(Hash)

      v = value_obj["value"]
      v_violations = check_value(label, v, spec, r_str)
      violations.concat(v_violations)
    end

    violations
  end

  private

  def load_modules
    @modules = {}
    return unless @modules_dir.exist?
    Pathname.glob(@modules_dir + "*.yaml").each do |f|
      name = f.basename.to_s.sub(/\.yaml$/, "")
      @modules[name] = YAML.load_file(f)
    end
  end

  def load_r_schema(r_str)
    path = @schema_dir + "#{r_str}.yaml"
    return nil unless path.exist?
    YAML.load_file(path)
  end

  # If spec says _inherits_from_module, look up the full spec from the module
  def resolve_spec(label, spec)
    return nil unless spec.is_a?(Hash)
    return spec unless spec["_inherits_from_module"]
    @modules.each_value do |mod|
      chars = mod["characteristics"] || {}
      return chars[label] if chars.key?(label)
    end
    nil
  end

  # ─── Type checkers ─────────────────────────────────────────────────

  def check_value(label, value, spec, r_str)
    type = spec["type"]
    return [] unless type

    case type
    when "enum"         then check_enum(label, value, spec)
    when "enum_multi"   then check_enum_multi(label, value, spec)
    when "numeric", "int" then check_numeric(label, value, spec.merge("integer" => type == "int" || spec["integer"]))
    when "range"        then check_range(label, value, spec)
    when "string"       then check_string(label, value, spec)
    when "compound"     then check_compound(label, value, spec)
    when "boolean"      then check_boolean(label, value, spec)
    else
      [{ label: label, issue: "unknown_type", type: type }]
    end
  end

  def check_enum(label, value, spec)
    return [] if value.nil?
    allowed = spec["values"] || []
    return [] if allowed.empty?
    allow_text = spec["allow_text_values"] || []
    v = value.to_s.strip
    return [] if allow_text.include?(v)
    return [] if allowed.include?(v)
    [{ label: label, bad: [v], allowed: allowed, type: "enum" }]
  end

  def check_enum_multi(label, value, spec)
    return [] if value.nil?
    allowed = spec["values"] || []
    return [] if allowed.empty?
    vals = to_array(value).map { |v| v.is_a?(Numeric) ? v.to_s : v.to_s.strip }
    vals = vals.reject(&:empty?)
    return [] if vals.empty?
    bad = vals.reject { |v| allowed.include?(v) }
    return [] if bad.empty?
    [{ label: label, bad: bad, allowed: allowed, type: "enum_multi" }]
  end

  def check_numeric(label, value, spec)
    return [] if value.nil?
    # Allow text stand-ins like "Not applicable"
    allow_text = spec["allow_text_values"] || []
    return [] if allow_text.include?(value.to_s)

    # Unwrap nested value-objects and arrays
    v = value
    v = v[0] if v.is_a?(Array) && v.size == 1
    if v.is_a?(Hash) && v.key?("value")
      v = v["value"]
    end
    # Extract from range dict: {min: X} or {max: Y}
    if v.is_a?(Hash)
      v = v.transform_keys(&:to_s)
      v = v["min"] || v["max"] || v["value"]
    end

    n = coerce_numeric(v)
    return [{ label: label, bad: [value], type: "numeric", reason: "not_a_number" }] unless n

    if spec["integer"] && !n.is_a?(Integer)
      # Accept floats that are whole numbers
      return [{ label: label, bad: [value], type: "numeric", reason: "not_integer" }] unless n == n.to_i
    end

    min = spec["min"]
    max = spec["max"]
    if min && n < min
      return [{ label: label, bad: [value], type: "numeric", reason: "below_min", min: min }]
    end
    if max && n > max
      return [{ label: label, bad: [value], type: "numeric", reason: "above_max", max: max }]
    end
    []
  end

  def check_range(label, value, spec)
    return [] if value.nil?
    allow_text = spec["allow_text_values"] || []
    return [] if allow_text.include?(value.to_s)

    # Accept a bare number as a degenerate range
    if value.is_a?(Numeric)
      return []
    end

    # Normalize: unwrap array-of-one-hash, stringify keys
    v = value
    v = v[0] if v.is_a?(Array) && v.size == 1 && v[0].is_a?(Hash)
    if v.is_a?(Hash)
      v = v.transform_keys(&:to_s)
    end

    unless v.is_a?(Hash) && (v.key?("min") || v.key?("max"))
      parsed = parse_range_string(value.to_s)
      return [{ label: label, bad: [value], type: "range", reason: "not_a_range" }] unless parsed
    end

    min_val = v.is_a?(Hash) ? v["min"] : (parsed ? parsed[0] : nil)
    max_val = v.is_a?(Hash) ? v["max"] : (parsed ? parsed[1] : nil)

    violations = []
    if min_val && !min_val.is_a?(Numeric) && min_val.to_s != ""
      n = coerce_numeric(min_val)
      violations << { label: label, bad: [min_val], type: "range", reason: "min_not_numeric" } unless n
    end
    if max_val && !max_val.is_a?(Numeric) && max_val.to_s != ""
      n = coerce_numeric(max_val)
      violations << { label: label, bad: [max_val], type: "range", reason: "max_not_numeric" } unless n
    end
    violations
  end

  def check_string(label, value, spec)
    return [] if value.nil?
    pattern = spec["pattern"]
    return [] unless pattern
    return [] unless value.is_a?(String)
    return [] if value.match?(Regexp.new(pattern))
    [{ label: label, bad: [value], type: "string", pattern: pattern }]
  end

  def check_compound(label, value, spec)
    return [] if value.nil?
    structure = spec["structure"]
    return [] unless structure
    return [{ label: label, bad: [value], type: "compound", reason: "not_a_hash" }] unless value.is_a?(Hash)
    violations = []
    structure.each do |sub_label, sub_spec|
      next unless sub_spec.is_a?(Hash)
      sub_val = value[sub_label]
      next if sub_val.nil? # optional sub-fields
      sub_violations = check_value("#{label}.#{sub_label}", sub_val, sub_spec, nil)
      violations.concat(sub_violations)
    end
    violations
  end

  def check_boolean(label, value, spec)
    return [] if value.nil?
    v = value.to_s.downcase
    return [] if %w[true false yes no applicable not_applicable not-applicable 1 0].include?(v)
    [{ label: label, bad: [value], type: "boolean" }]
  end

  # ─── Helpers ───────────────────────────────────────────────────────

  def to_array(v)
    return [] if v.nil?
    return v if v.is_a?(Array)
    [v]
  end

  def coerce_numeric(v)
    case v
    when Integer, Float then v
    when String
      s = v.strip.gsub(",", ".") # European decimal
      begin
        s.match?(/\./) ? Float(s) : Integer(s)
      rescue ArgumentError
        nil
      end
    else nil
    end
  end

  def parse_range_string(s)
    # "10-40", "10...40", "10 – 40", "-10/+40"
    m = s.match(/^(-?[\d.]+)\s*(?:[-…\/]|to)\s*\+?(-?[\d.]+)$/i)
    return nil unless m
    [coerce_numeric(m[1]), coerce_numeric(m[2])].compact
  end
  end
end

# ─── CLI entry point ──────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  ROOT = Pathname.new(File.expand_path("../..", __dir__))
  YAML_ROOT = ROOT + "yaml"
  SCHEMA_DIR = ROOT + "schema"

  validator = TypeValidator.new(schema_dir: SCHEMA_DIR)

  per_r = Hash.new { |h, k| h[k] = { total: 0, violations: 0, by_type: Hash.new(0), samples: [] } }
  all_violations = []

  Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
    r_str = yp.parent.parent.basename.to_s
    per_r[r_str][:total] += 1
    vs = validator.validate_cert(yp)
    next if vs.empty?
    per_r[r_str][:violations] += vs.size
    vs.first(3).each { |v| per_r[r_str][:samples] << { cert: yp.basename.to_s, **v } }
    vs.each { |v| per_r[r_str][:by_type][v[:type] || v[:issue]] += 1 }
    all_violations.concat(vs.map { |v| { R: r_str, cert: yp.basename.to_s, **v } })
  end

  puts "=== PER-R SUMMARY ==="
  puts format("%-6s %8s %12s  %s", "R", "certs", "violations", "by_type")
  per_r.keys.sort_by { |r| r[1..].to_i }.each do |r|
    v = per_r[r]
    flag = v[:violations].zero? ? "✓" : "✗"
    by_type_str = v[:by_type].map { |k, n| "#{k}=#{n}" }.join(", ")
    puts format("  %s %-4s %8d %12d  %s", flag, r, v[:total], v[:violations], by_type_str)
  end

  puts
  puts "=== SAMPLE VIOLATIONS (first 30) ==="
  all_violations.first(30).each do |v|
    puts "  [#{v[:R]}] #{v[:cert]}"
    if v[:issue]
      puts "      issue: #{v[:issue]}"
    else
      detail = case v[:type]
               when "enum", "enum_multi" then "#{v[:bad]} not in #{v[:allowed]}"
               when "numeric" then "#{v[:bad]} (#{v[:reason]})"
               when "range" then "#{v[:bad]} (#{v[:reason]})"
               when "string" then "#{v[:bad]} doesn't match /#{v[:pattern]}/"
               when "compound" then "#{v[:bad]} (#{v[:reason]})"
               when "boolean" then "#{v[:bad]} not boolean"
               else v[:bad].to_s
               end
      puts "      #{v[:label]}: #{detail}"
    end
  end

  total = all_violations.size
  puts
  puts "Total violations: #{total}"
end
