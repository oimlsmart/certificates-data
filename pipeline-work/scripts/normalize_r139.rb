#!/usr/bin/env ruby
# frozen_string_literal: true
# Normalize R139 cert YAMLs: fill empty recommendation, fix member_state IDs, dedup model_level entries.

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml/R139/2018"

MEMBER_STATE_MAP = {
  "CZ" => "Czech Republic",
  "NL" => "The Netherlands",
  "DK" => "Denmark",
  "GB" => "United Kingdom of Great Britain and Northern Ireland",
  "CH" => "Switzerland",
  "DE" => "Germany",
  "FR" => "France",
}

def stringify_keys(obj)
  if obj.is_a?(Hash)
    obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys(v) }
  elsif obj.is_a?(Array)
    obj.map { |v| stringify_keys(v) }
  else
    obj
  end
end

def dedup_model_level(ml)
  # Merge entries with the same attribute by combining their values arrays
  return ml unless ml.is_a?(Array)
  merged = {}
  order = []
  ml.each do |e|
    a = e["attribute"]
    unless merged.key?(a)
      merged[a] = e.dup
      order << a
    end
    existing = merged[a]
    # Combine values
    existing_vals = existing["values"] || []
    new_vals = e["values"] || []
    # Merge: keep all values, but ensure unique (model, value) pairs
    seen = Set.new if defined?(Set)
    combined = existing_vals + new_vals
    # Just append for now (preserve data)
    existing["values"] = combined.uniq { |v| v["model"].to_s + "_" + v["value"].to_s }
  end
  order.map { |a| merged[a] }
end

require "set"

fixed = 0
counts = Hash.new(0)

Pathname.glob(YAML_ROOT + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  data = stringify_keys(data)
  modified = false

  # 1. Fix member_state from ID to country name
  cert = data["certificate"] || {}
  ms = cert["member_state"]
  if MEMBER_STATE_MAP.key?(ms)
    cert["member_state"] = MEMBER_STATE_MAP[ms]
    counts[:member_state] += 1
    modified = true
  end

  # 2. Fill empty recommendation
  rec = data["recommendation"]
  chars = data["characteristics"] || {}
  if rec.nil? || rec.empty?
    # Try to extract accuracy class from type_level
    tl = chars["type_level"] || {}
    ac = []
    tl.each do |label, vobj|
      next unless label.to_s =~ /accuracy_class/
      next unless vobj.is_a?(Hash)
      v = vobj["value"]
      next if v.nil?
      ac << (v.is_a?(String) ? v : v.to_s)
    end
    data["recommendation"] = {
      "id" => "R139",
      "edition" => 2018,
      "amendment" => nil,
      "scheme" => cert["scheme"] || "A",
      "accuracy_classes" => ac
    }
    counts[:empty_rec] += 1
    modified = true
  elsif rec.is_a?(Hash)
    rec["id"] ||= "R139"
    rec["edition"] ||= 2018
    rec["scheme"] ||= cert["scheme"] || "A"
    if (rec["accuracy_classes"].nil? || rec["accuracy_classes"].empty?) && (rec["id"].to_s == "R139")
      tl = chars["type_level"] || {}
      ac = []
      tl.each do |label, vobj|
        next unless label.to_s =~ /accuracy_class/
        next unless vobj.is_a?(Hash)
        v = vobj["value"]
        next if v.nil?
        ac << (v.is_a?(String) ? v : v.to_s)
      end
      unless ac.empty?
        rec["accuracy_classes"] = ac
        counts[:empty_ac] += 1
        modified = true
      end
    end
  end

  # 3. Dedup model_level entries with same attribute
  ml = chars["model_level"]
  if ml.is_a?(Array) && ml.any?
    attrs = ml.map { |e| e["attribute"] }
    if attrs.uniq.size < attrs.size
      chars["model_level"] = dedup_model_level(ml)
      counts[:dup_model_level] += 1
      modified = true
    end
  end

  next unless modified
  yp.write(YAML.dump(data))
  fixed += 1
end

puts "Fixed #{fixed} R139 certs"
counts.sort.each { |k, v| puts "  #{k}: #{v}" }
