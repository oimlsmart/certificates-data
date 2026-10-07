#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-family statistics over the full extracted tier, matching the shape the
# frozen pipeline writes (oiml_cs/use_cases/process_recommendation.py), with
# sample_size now counting every yaml record of the family rather than the
# original extraction sample cap. Deterministic; regenerates stats/R*.yaml.

require "yaml"
require "fileutils"

REPO = File.expand_path("..", __dir__)

def py_str(v)
  return "None" if v.nil?
  return v.to_s unless [true, false].include?(v)
  v.to_s.capitalize
end

def top_values(values, limit = 10)
  scalars = Hash.new(0)
  ranges = Hash.new(0)
  strings = Hash.new(0)
  values.each do |v|
    val = v["value"]
    if val.is_a?(Hash) && (val.key?("min") || val.key?("max"))
      ranges["min=#{py_str(val['min'])}, max=#{py_str(val['max'])}"] += 1
    elsif val.is_a?(Numeric)
      scalars[val] += 1
    else
      strings[val.to_s] += 1
    end
  end
  out = []
  scalars.sort_by { |_k, c| -c }.first(limit).each { |val, c| out << { "value" => val, "count" => c } }
  ranges.sort_by { |_k, c| -c }.first(limit).each { |spec, c| out << { "range" => spec, "count" => c } }
  strings.sort_by { |_k, c| -c }.first(limit).each { |s, c| out << { "value" => s, "count" => c } }
  out.first(limit)
end

def build_family(records)
  type_level = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
  model_attrs = Hash.new(0)
  config_attrs = Hash.new(0)
  matrix_names = Hash.new(0)
  summary = Hash.new(0)

  records.each do |p|
    tl = p.dig("characteristics", "type_level") || {}
    tl.each do |label, cv|
      next unless cv.is_a?(Hash) && !cv["value"].nil?
      unit = cv.is_a?(Hash) ? cv["unit_symbol"] : nil
      type_level[label][unit || nil] << { "value" => cv["value"], "unit_id" => cv["unit_id"] }
    end
    Array(p.dig("characteristics", "model_level")).each { |e| model_attrs[e["attribute"]] += 1 }
    Array(p.dig("characteristics", "config_level")).each { |e| config_attrs[e["attribute"]] += 1 }
    Array(p["matrix_tables"]).each { |mt| matrix_names[mt["name"]] += 1 }
    summary["certs_with_model_family"] += 1 if p["model_family"]
    summary["certs_with_components"] += 1 unless Array(p["components"]).empty?
    summary["certs_with_matrix_tables"] += 1 unless Array(p["matrix_tables"]).empty?
    summary["certs_with_footnotes"] += 1 unless Array(p["footnotes"]).empty?
    summary["total_model_variants"] += Array(p.dig("model_family", "models")).size if p["model_family"]
    summary["total_matrix_tables"] += Array(p["matrix_tables"]).size
  end

  n = records.size
  summary = %w[certs_with_model_family certs_with_components certs_with_matrix_tables
               certs_with_footnotes total_model_variants total_matrix_tables]
               .map { |k| [k, summary[k]] }.to_h
  section = {}
  type_level.keys.sort.each do |attr|
    by_unit = type_level[attr]
    total = by_unit.values.sum(&:size)
    next if total.zero?
    entry = { "fill_rate" => n.zero? ? 0 : (total.to_f / n).round(3), "present_count" => total }
    if by_unit.size == 1
      unit = by_unit.keys.first
      vals = by_unit.values.first
      entry["unit_symbol"] = unit
      entry["unit_id"] = vals.first["unit_id"] if vals.first["unit_id"]
      entry["top_values"] = top_values(vals)
    else
      entry["by_unit"] = {}
      by_unit.sort_by { |_u, vs| -vs.size }.each do |unit, vals|
        sub = { "count" => vals.size, "top_values" => top_values(vals) }
        sub["unit_id"] = vals.first["unit_id"] if vals.first["unit_id"]
        entry["by_unit"][unit || "null"] = sub
      end
    end
    section[attr] = entry
  end

  {
    "recommendation" => nil,
    "sample_size" => n,
    "summary" => summary,
    "type_level_characteristics" => section,
    "model_level_attributes" => model_attrs.sort_by { |_k, v| -v }.to_h,
    "config_level_attributes" => config_attrs.sort_by { |_k, v| -v }.to_h,
    "matrix_table_names" => matrix_names.sort_by { |_k, v| -v }.to_h,
  }
end

by_family = Hash.new { |h, k| h[k] = [] }
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  fam = f.split("/")[-3]
  by_family[fam] << YAML.unsafe_load_file(f)
end

by_family.keys.sort.each do |fam|
  stats = build_family(by_family[fam])
  stats["recommendation"] = fam
  out = "#{REPO}/stats/#{fam}.yaml"
  FileUtils.mkdir_p(File.dirname(out))
  File.write(out, stats.to_yaml(line_width: 100).sub(/\A---\n/, ""))
  puts "#{fam}: sample_size=#{stats['sample_size']} attrs=#{stats['type_level_characteristics'].size}"
end
