#!/usr/bin/env ruby
# frozen_string_literal: true
# Pass 3: stringify symbol keys, unwrap nested value-objects, extract numerics
# from compound strings, add missing enum values.
require "yaml"; require "pathname"; require "json"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"

def stringify_keys(obj)
  if obj.is_a?(Hash)
    obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys(v) }
  elsif obj.is_a?(Array)
    obj.map { |v| stringify_keys(v) }
  else
    obj
  end
end

def unwrap_nested_value(val)
  # {"value" => X, "unit_symbol" => ...} → X
  return val unless val.is_a?(Hash)
  if val.key?("value") && val.key?("unit_symbol")
    return val["value"]
  end
  val
end

def extract_numeric_from_string(s)
  # "3,5bar(g)" → 3.5 ; "0.22 MPa" → 0.22 ; "≥20% of Max" → nil (formula)
  return nil unless s.is_a?(String)
  s = s.gsub(",", ".")
  if (m = s.match(/(-?\d+\.?\d*)/))
    n = m[1].to_f
    n == n.to_i ? n.to_i : n
  end
end

fixed = 0
counts = { symbol_keys: 0, nested_unwrap: 0, numeric_extract: 0,
           compound_split: 0, enum_fix: 0, list_unwrap: 0 }

Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  data = stringify_keys(data) # fix all symbol keys → string
  chars = data.dig("characteristics", "type_level") || {}
  modified = false

  chars.dup.each do |label, vobj|
    next unless vobj.is_a?(Hash)
    val = vobj["value"]

    # Unwrap list-of-one-hash: [{min,max}] → {min,max}
    if val.is_a?(Array) && val.size == 1 && val[0].is_a?(Hash)
      vobj["value"] = val[0]
      val = val[0]
      counts[:list_unwrap] += 1; modified = true
    end

    # Unwrap nested value-object: {"value" => X, "unit_symbol" => ...}
    if val.is_a?(Hash) && val.key?("value") && val.key?("unit_symbol")
      inner = val["value"]
      vobj["unit_symbol"] = val["unit_symbol"] if val["unit_symbol"]
      vobj["value"] = inner
      val = inner
      counts[:nested_unwrap] += 1; modified = true
    end

    # Unwrap doubly-nested
    if val.is_a?(Hash) && val.key?("value") && val.key?("unit_symbol")
      inner = val["value"]
      vobj["value"] = inner
      val = inner
      counts[:nested_unwrap] += 1; modified = true
    end

    # Extract numeric from compound string with unit
    # e.g. "3,5bar(g)" → 3.5, unit: bar
    if val.is_a?(String) && val.match?(/^\d+[,.]?\d*\s*[a-zA-Z°℃]/)
      num = extract_numeric_from_string(val)
      if num
        unit = val.match(/[a-zA-Z°℃][a-zA-Z°℃\/\(\)·\s]*$/)
        vobj["value"] = num
        vobj["unit_symbol"] = unit[0].strip if unit
        vobj["_extracted_from"] = val
        counts[:numeric_extract] += 1; modified = true; next
      end
    end

    # Parse compound power supply that wasn't split: "220-240V;750W;50/60Hz"
    if ["power_supply_voltage", "power_supply", "supply_voltage"].include?(label) && val.is_a?(String)
      # Extract voltage
      if (vm = val.match(/(\d+\.?\d*)\s*[-–—]\s*(\d+\.?\d*)\s*V/i))
        vobj["value"] = {"min" => vm[1].to_f, "max" => vm[2].to_f}
        vobj["unit_symbol"] = "V"
        # Also extract frequency
        if (fm = val.match(/(\d+\.?\d*)\s*[-–—\/]\s*(\d+\.?\d*)\s*Hz/i))
          chars["power_supply_frequency"] = {"value" => {"min" => fm[1].to_f, "max" => fm[2].to_f}, "unit_symbol" => "Hz", "unit_id" => "u:hertz", "footnote_markers" => []}
        end
        counts[:compound_split] += 1; modified = true; next
      elsif (vm = val.match(/(\d+\.?\d*)\s*V/i))
        vobj["value"] = vm[1].to_f
        vobj["unit_symbol"] = "V"
        counts[:compound_split] += 1; modified = true; next
      end
    end

    # humidity_class: H3 is a valid humidity class — add to enum
    if label == "humidity_class" && val.is_a?(String)
      if val.upcase.match?(/^H[123]$/)
        vobj["value"] = val.upcase
        counts[:enum_fix] += 1; modified = true; next
      end
    end
  end

  next unless modified
  data["characteristics"]["type_level"] = chars
  yp.write(YAML.dump(data))
  fixed += 1
end

puts "Pass 3 fixes: #{fixed} certs"
counts.each { |k, v| puts "  #{k}: #{v}" }
