#!/usr/bin/env ruby
# frozen_string_literal: true
# Normalize R134 cert YAMLs: fix empty recommendation, wrong scheme, redundant {min,max} for singletons,
# number_of_sensor_rows numeric-vs-list, missing accuracy_classes extracted from type_level.

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml/R134/2006"

def stringify_keys(obj)
  if obj.is_a?(Hash)
    obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys(v) }
  elsif obj.is_a?(Array)
    obj.map { |v| stringify_keys(v) }
  else
    obj
  end
end

def scheme_from_cert_number(num)
  # R134/2006-A-CH1-22.01 → A ; R134/2006-NL1-2014-01 → A (older format) ; R134/2006-B-CZ1-20.01 → B
  return "A" unless num
  if num =~ /-(A|B)-/
    Regexp.last_match(1)
  elsif num =~ /-(A|B)\d*-/
    Regexp.last_match(1)
  else
    "A"
  end
end

def collapse_singleton_range(vobj)
  # If value is {min: X, max: X} → just X
  val = vobj.is_a?(Hash) ? vobj["value"] : nil
  return false unless val.is_a?(Hash)
  return false unless val.key?("min") && val.key?("max")
  if val["min"] == val["max"]
    vobj["value"] = val["min"]
    return true
  end
  false
end

def extract_accuracy_classes(chars)
  # Look at type_level and model_level for accuracy_class* fields
  classes = []
  tl = chars["type_level"] || {}
  tl.each do |label, vobj|
    next unless vobj.is_a?(Hash)
    next unless label.to_s =~ /accuracy_class/
    val = vobj["value"]
    next if val.nil?
    if val.is_a?(String)
      # "2 and higher" → "2" ; "E" → "E"
      m = val.match(/^([A-Za-z0-9.]+)\s+and\s+higher$/)
      classes << (m ? m[1] : val)
    else
      classes << val.to_s
    end
  end
  ml = chars["model_level"] || []
  ml.each do |entry|
    next unless entry["attribute"].to_s =~ /accuracy_class/
    vals = entry["values"] || []
    vals.each do |row|
      v = row["value"]
      next if v.nil?
      if v.is_a?(String)
        m = v.match(/^([A-Za-z0-9.]+)\s+and\s+higher$/)
        classes << (m ? m[1] : v)
      else
        classes << v.to_s
      end
    end
  end
  classes.uniq
end

fixed = 0
counts = Hash.new(0)

Pathname.glob(YAML_ROOT + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  data = stringify_keys(data)
  modified = false

  # 1. Fix scheme
  cert = data["certificate"] || {}
  num = cert["number"]
  if cert["scheme"].nil? || cert["scheme"] == "R134" || cert["scheme"].to_s.empty?
    new_scheme = scheme_from_cert_number(num)
    cert["scheme"] = new_scheme
    counts[:scheme] += 1
    modified = true
  end

  # 2. Fill empty recommendation
  rec = data["recommendation"]
  if rec.nil? || rec.empty?
    chars = data["characteristics"] || {}
    classes = extract_accuracy_classes(chars)
    data["recommendation"] = {
      "id" => "R134",
      "edition" => 2006,
      "amendment" => nil,
      "scheme" => cert["scheme"] || "A",
      "accuracy_classes" => classes
    }
    counts[:recommendation] += 1
    modified = true
  elsif rec.is_a?(Hash)
    # Ensure id/edition present
    rec["id"] ||= "R134"
    rec["edition"] ||= 2006
    rec["scheme"] ||= cert["scheme"] || "A"
    if rec["accuracy_classes"].nil? || rec["accuracy_classes"].empty?
      chars = data["characteristics"] || {}
      classes = extract_accuracy_classes(chars)
      unless classes.empty?
        rec["accuracy_classes"] = classes
        counts[:accuracy_classes] += 1
        modified = true
      end
    end
  end

  # 3. Collapse singleton ranges
  chars = data["characteristics"] || {}
  tl = chars["type_level"]
  if tl.is_a?(Hash)
    tl.each do |label, vobj|
      next unless vobj.is_a?(Hash)
      if collapse_singleton_range(vobj)
        counts[:singleton_range] += 1
        modified = true
      end
    end
  end

  # 4. Fix number_of_sensor_rows: numeric like 234 (without comma) when source said "2,3,4"
  if tl.is_a?(Hash) && tl.key?("number_of_sensor_rows")
    vobj = tl["number_of_sensor_rows"]
    if vobj.is_a?(Hash)
      val = vobj["value"]
      # Heuristic: 3-digit integer where digits are sequential like 234
      if val.is_a?(Integer) && val.between?(2, 999)
        digits = val.to_s.chars.map(&:to_i)
        if digits.size >= 2 && digits.uniq.size >= 2 && digits.all? { |d| d.between?(1, 9) }
          vobj["value"] = digits
          vobj["_extracted_from"] = "numeric-form (was #{val})"
          counts[:sensor_rows] += 1
          modified = true
        end
      end
    end
  end

  next unless modified
  yp.write(YAML.dump(data))
  fixed += 1
end

puts "Fixed #{fixed}/#{Pathname.glob(YAML_ROOT + '*.yaml').size} R134 certs"
counts.sort.each { |k, v| puts "  #{k}: #{v}" }
