#!/usr/bin/env ruby
# frozen_string_literal: true
# Second-pass fixes: unwrap nested structures, handle remaining violations.
require "yaml"; require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"

fixed = 0
Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  chars = data.dig("characteristics", "type_level") || {}
  modified = false

  chars.dup.each do |label, vobj|
    next unless vobj.is_a?(Hash)
    val = vobj["value"]

    # Fix: unwrap [{min,max}] → {min,max} (list wrapping a single range dict)
    if val.is_a?(Array) && val.size == 1 && val[0].is_a?(Hash) && (val[0]["min"] || val[0]["max"])
      vobj["value"] = val[0]
      modified = true; next
    end

    # Fix: unwrap nested {"value" => X, "unit_symbol" => ...} where the inner "value"
    # is itself a dict — GLM sometimes nests value-objects
    if val.is_a?(Hash) && val.key?("value") && val.key?("unit_symbol") && val["value"].is_a?(Hash)
      inner = val["value"]
      vobj["value"] = inner
      vobj["unit_symbol"] ||= val["unit_symbol"]
      modified = true; next
    end

    # Fix: parse range strings that weren't caught before
    # e.g. "-40-+70℃" or "-10 to +55 °C"
    if val.is_a?(String)
      # Strip unit and parse
      stripped = val.gsub(/[℃°]/, "").gsub(/C\b/, "")
      m = stripped.match(/(-?\d+\.?\d*)\s*(?:[-–—…]|to)\s*\+?(-?\d+\.?\d*)/i)
      if m
        vobj["value"] = {"min" => m[1].sub(",", ".").to_f, "max" => m[2].sub(",", ".").to_f}
        vobj["_parsed_from"] = val
        modified = true; next
      end
    end

    # Fix: float that should be int (for number_of_scale_intervals etc.)
    if val.is_a?(Float) && val == val.to_i
      vobj["value"] = val.to_i
      modified = true; next
    end

    # Fix: string that looks like a number → coerce
    if val.is_a?(String) && val.match?(/^\d+\.?\d*$/)
      num = val.match?(/\./) ? val.to_f : val.to_i
      vobj["value"] = num
      modified = true; next
    end

    # Fix: humidity_class compound strings → extract first matching value
    if label == "humidity_class" && val.is_a?(String)
      if val.match?(/non.?condensing/i)
        vobj["value"] = "non-condensing"; modified = true; next
      elsif val.match?(/condensing/i) && !val.match?(/non/i)
        vobj["value"] = "condensing"; modified = true; next
      elsif val.match?(/\bCH\b/)
        vobj["value"] = "CH"; modified = true; next
      end
    end

    # Fix: weighing_range "Single-interval" → "Single interval"
    if label == "weighing_range" && val.is_a?(String)
      fixed_val = val.gsub(/[-_]/, " ").strip
      if fixed_val != val
        vobj["value"] = fixed_val
        modified = true; next
      end
    end
  end

  next unless modified
  data["characteristics"]["type_level"] = chars
  yp.write(YAML.dump(data))
  fixed += 1
end

puts "Second-pass fixes applied to #{fixed} certs"
