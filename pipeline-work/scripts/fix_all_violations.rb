#!/usr/bin/env ruby
# frozen_string_literal: true
# Fix ALL type violations across 880 cert YAMLs.
#
# Fixes applied:
#   1. Enum case: "Non-condensing" → "non-condensing" (match canonical case)
#   2. Power supply compound: "100-240VAC,47-63Hz" → split into 3 aspects
#   3. Environmental classes: "M1, E1, H3" → {mechanical:M1, electromagnetic:E1, humidity:H3}
#   4. R60 accuracy_class "C3" → accuracy_class:"C" + max_intervals:3000
#   5. Numeric from range: {min:5} where number expected → 5
#   6. Int from float: 5.0 → 5
#   7. Range from string: "10-40" → {min:10, max:40}
#   8. Enum text variants: "Single-interval" → "Single interval"

require "yaml"
require "pathname"
require "set"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"
SCHEMA_DIR = ROOT + "schema"
MODULES_DIR = SCHEMA_DIR + "_modules"

# ─── Helpers ───────────────────────────────────────────────────────────

def load_modules
  mods = {}
  Pathname.glob(MODULES_DIR + "*.yaml").each do |f|
    name = f.basename.to_s.sub(/\.yaml$/, "")
    mods[name] = YAML.load_file(f)
  end
  mods
end

def load_r_schema(r_str)
  path = SCHEMA_DIR + "#{r_str}.yaml"
  return nil unless path.exist?
  YAML.load_file(path)
end

def load_enum_values(r_str, label)
  schema = load_r_schema(r_str)
  return nil unless schema
  aspect = schema.dig("scope", "aspects", label)
  return aspect["values"] if aspect && aspect["values"]
  nil
end

def to_num(s)
  return s if s.is_a?(Numeric)
  s = s.to_s.strip.gsub(",", ".")
  begin
    s.match?(/^-?\d+$/) ? s.to_i : s.to_f
  rescue ArgumentError
    nil
  end
end

def parse_range_str(s)
  # "10-40", "-10/+40", "10...40", "10 to 40"
  m = s.to_s.match(/(-?[\d.]+)\s*(?:[-–—\/…]|\bto\b)\s*\+?(-?[\d.]+)/i)
  return nil unless m
  [to_num(m[1]), to_num(m[2])]
end

def extract_unit(s)
  # Extract trailing unit: "V", "Hz", "°C", "kg", "L/min", etc.
  m = s.to_s.match(/([a-zA-Z°℃⁻¹²³\/\.\·]+)\s*$/)
  m ? m[1] : nil
end

def extract_voltage_ac_dc(s)
  ac = s.match?(/\bAC\b/i)
  dc = s.match?(/\bDC\b/i)
  return "AC/DC" if ac && dc
  return "AC" if ac
  return "DC" if dc
  nil
end

# ─── Fix 1: Enum case normalization ───────────────────────────────────

def fix_enum_case(value, allowed)
  return nil unless value.is_a?(String) && allowed
  allowed.each do |canonical|
    return canonical if value.downcase == canonical.downcase
  end
  # Fuzzy: strip punctuation/hyphens
  norm = value.downcase.gsub(/[-_]/, " ").strip
  allowed.each do |canonical|
    return canonical if canonical.downcase.gsub(/[-_]/, " ").strip == norm
  end
  nil
end

# ─── Fix 2: Power supply compound splitting ───────────────────────────

def split_power_supply(raw_str)
  # "100-240VAC,47-63Hz" → {voltage:{min,max}, frequency:{min,max}, type:AC}
  # "9-36 VDC" → {voltage:{min:9,max:36}, type:DC}
  # "110-240V AC 50/60Hz" → same
  result = {}

  # Extract AC/DC
  type = extract_voltage_ac_dc(raw_str)
  result[:type] = type if type

  # Extract voltage range: look for digits followed by V
  if (vm = raw_str.match(/(\d+\.?\d*)\s*[-–—]\s*(\d+\.?\d*)\s*V/i))
    result[:voltage] = { min: to_num(vm[1]), max: to_num(vm[2]) }
  elsif (vm = raw_str.match(/(\d+\.?\d*)\s*V/i))
    result[:voltage] = { min: to_num(vm[1]), max: to_num(vm[1]) }
  end

  # Extract frequency: digits followed by Hz
  if (fm = raw_str.match(/(\d+\.?\d*)\s*[-–—\/]\s*(\d+\.?\d*)\s*Hz/i))
    result[:frequency] = { min: to_num(fm[1]), max: to_num(fm[2]) }
  elsif (fm = raw_str.match(/(\d+\.?\d*)\s*Hz/i))
    result[:frequency] = { min: to_num(fm[1]), max: to_num(fm[1]) }
  end

  result
end

# ─── Fix 3: Environmental classes decomposition ──────────────────────

def decompose_env_classes(raw_str)
  # "M1, E1, H3" or "M1/E1/H3" or "M1 E1 H3"
  result = {}
  parts = raw_str.to_s.split(/[,;\/\s]+/).reject(&:empty?)
  parts.each do |p|
    case p.upcase
    when /^M\d$/ then result["mechanical"] = p.upcase
    when /^E\d$/ then result["electromagnetic"] = p.upcase
    when /^H\d$/ then result["humidity"] = p.upcase
    when /^C\d?$/ then result["climatic"] = p.upcase
    end
  end
  result.empty? ? nil : result
end

# ─── Fix 4: R60 accuracy_class C3 decomposition ───────────────────────

def decompose_r60_accuracy_class(value, r_str)
  # "C3" → accuracy_class: "C", max_intervals: 3000
  # "D1" → accuracy_class: "D", max_intervals: 1000
  # "C6" → accuracy_class: "C", max_intervals: 6000
  # Only for Letter+Digit system (R60 load cells)
  return nil unless r_str == "R60"
  vals = value.is_a?(Array) ? value : [value]
  decomposed = []
  vals.each do |v|
    s = v.to_s.strip
    if (m = s.match(/^([A-D])(\d)$/))
      letter = m[1]
      digit = m[2].to_i
      max_intervals = digit * 1000
      decomposed << { accuracy_class: letter, max_intervals: max_intervals }
    else
      decomposed << { accuracy_class: s, max_intervals: nil }
    end
  end
  decomposed
end

def load_enum_from_modules(label)
  load_modules.each_value do |mod|
    chars = mod["characteristics"] || {}
    spec = chars[label]
    return spec["values"] if spec && spec["values"]
  end
  nil
end

def get_aspect_type(r_str, label)
  schema = load_r_schema(r_str)
  return nil unless schema
  aspect = schema.dig("scope", "aspects", label)
  return aspect["type"] if aspect && aspect["type"] && !aspect["_inherits_from_module"]
  # Check R-specific
  r_spec = schema.dig("r_specific_aspects", label)
  return r_spec["type"] if r_spec && r_spec["type"]
  # Check modules
  load_modules.each_value do |mod|
    chars = mod["characteristics"] || {}
    spec = chars[label]
    return spec["type"] if spec && spec["type"]
  end
  nil
end

# ─── Main fix logic ───────────────────────────────────────────────────

stats = { fixed: 0, accuracy_decomposed: 0, power_split: 0, env_decomposed: 0,
          enum_case_fixed: 0, range_parsed: 0, numeric_coerced: 0, int_truncated: 0 }

Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
  r_str = yp.parent.parent.basename.to_s
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)

  chars = data.dig("characteristics", "type_level") || {}
  modified = false

  chars.dup.each do |label, value_obj|
    next unless value_obj.is_a?(Hash)
    raw = value_obj["value"]

    # ── Fix 4: R60 C3 decomposition ──
    if label == "accuracy_class" && r_str == "R60"
      decomposed = decompose_r60_accuracy_class(raw, r_str)
      if decomposed&.any? { |d| d[:max_intervals] }
        # Extract pure accuracy classes
        pure_classes = decomposed.map { |d| d[:accuracy_class] }.uniq
        value_obj["value"] = pure_classes.size == 1 ? pure_classes.first : pure_classes
        value_obj["_decomposed_from"] = raw
        modified = true
        stats[:accuracy_decomposed] += 1

        # Add max_intervals as separate aspect
        max_intervals_values = decomposed.map { |d| d[:max_intervals] }.compact.uniq
        unless max_intervals_values.empty?
          chars["maximum_number_of_load_cell_intervals_nlc"] = {
            "value" => max_intervals_values.size == 1 ? max_intervals_values.first : max_intervals_values,
            "unit_symbol" => nil,
            "unit_id" => nil,
            "footnote_markers" => [],
            "_derived_from_accuracy_class" => true,
          }
        end
        next
      end
    end

    # ── Fix 2: Power supply compound splitting ──
    if ["power_supply_voltage", "power_supply", "supply_voltage"].include?(label) && raw.is_a?(String)
      split = split_power_supply(raw)
      if split[:voltage] || split[:frequency] || split[:type]
        if split[:voltage]
          value_obj["value"] = split[:voltage]
          value_obj["unit_symbol"] = "V"
          modified = true
          stats[:power_split] += 1
        end
        if split[:frequency]
          chars["power_supply_frequency"] = {
            "value" => split[:frequency],
            "unit_symbol" => "Hz",
            "unit_id" => "u:hertz",
            "footnote_markers" => [],
          }
        end
        if split[:type]
          chars["power_supply_type"] = {
            "value" => split[:type],
            "unit_symbol" => nil,
            "unit_id" => nil,
            "footnote_markers" => [],
          }
        end
        next
      end
    end

    # ── Fix 3: Environmental classes decomposition ──
    if label == "environmental_classes" && raw.is_a?(String)
      decomposed = decompose_env_classes(raw)
      if decomposed
        value_obj["value"] = decomposed
        value_obj["_decomposed"] = true
        modified = true
        stats[:env_decomposed] += 1
        next
      end
    end

    # ── Fix 1: Enum case normalization ──
    if raw.is_a?(String)
      schema = load_r_schema(r_str)
      aspect = schema&.dig("scope", "aspects", label) if schema
      allowed = aspect&.dig("values")
      allowed ||= load_enum_from_modules(label)
      if allowed
        fixed = fix_enum_case(raw, allowed)
        if fixed && fixed != raw
          value_obj["value"] = fixed
          value_obj["_case_fixed"] = true
          modified = true
          stats[:enum_case_fixed] += 1
          next
        end
      end
    end

    # ── Fix 7: Range from string ──
    type = get_aspect_type(r_str, label)
    if type == "range" && raw.is_a?(String)
      range = parse_range_str(raw)
      if range
        value_obj["value"] = { "min" => range[0], "max" => range[1] }
        value_obj["_parsed_from_string"] = raw
        modified = true
        stats[:range_parsed] += 1
        next
      end
    end

    # ── Fix 5: Numeric from range dict ──
    if type == "numeric" && raw.is_a?(Hash) && (raw.key?("min") || raw.key?("max"))
      num = label.start_with?("minimum") ? raw["min"] : raw["max"]
      num ||= raw["min"] || raw["max"]
      if num.is_a?(Numeric)
        value_obj["value"] = num
        value_obj["_extracted_from_range"] = true
        modified = true
        stats[:numeric_coerced] += 1
        next
      end
    end

    # ── Fix 6: Int from float ──
    if type == "numeric" && raw.is_a?(Float) && raw == raw.to_i
      value_obj["value"] = raw.to_i
      modified = true
      stats[:int_truncated] += 1
      next
    end
  end

  next unless modified
  data["characteristics"]["type_level"] = chars
  yp.write(YAML.dump(data))
  stats[:fixed] += 1
end

puts "=== FIX SUMMARY ==="
puts "  certs modified:           #{stats[:fixed]}"
puts "  R60 C3 decomposed:        #{stats[:accuracy_decomposed]}"
puts "  power supply split:       #{stats[:power_split]}"
puts "  env classes decomposed:   #{stats[:env_decomposed]}"
puts "  enum case fixed:          #{stats[:enum_case_fixed]}"
puts "  range parsed from string: #{stats[:range_parsed]}"
puts "  numeric coerced from range: #{stats[:numeric_coerced]}"
puts "  int truncated from float: #{stats[:int_truncated]}"
