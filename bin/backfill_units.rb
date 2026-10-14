#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic unit_id backfill: resolve unit_symbol against unitsdb's own
# symbols, the frozen resolver's alias table, the local compounds, the local
# counts, and — for prefixed forms (mV, µV, dm³, mPa·s) — composition at
# lookup time: SI prefix symbol + base symbol from unitsdb's prefix and unit
# tables, with the prefix carried on the record's own Unit.prefix field.
# OIML count conventions (divisions, digits, DN) get _unit_kind per
# _core.yaml. No models, no pre-enumeration.

require "yaml"
require "json"
require "set"

REPO = File.expand_path("..", __dir__)

symbol_map = {}
File.read("#{REPO}/oiml_cs/units/units_db.py").scan(/"([^"]+)":\s*"(u:[^"]+)"/) { |s, id| symbol_map[s] = id }

unitsdb = YAML.safe_load(File.read(File.expand_path("~/src/unitsml/unitsdb/units.yaml")), aliases: true)
base_map = {}
(unitsdb["units"] || []).each do |u|
  uid = u["identifiers"].to_a.find { |x| x["id"].to_s.start_with?("u:") }&.dig("id")
  Array(u["symbols"]).each do |sym|
    %w[unicode ascii].each { |k| base_map[sym[k]] = uid if sym[k].is_a?(String) && uid }
  end
end

prefix_by_symbol = {
  "da" => "p:deka", "h" => "p:hecto", "k" => "p:kilo", "M" => "p:mega",
  "G" => "p:giga", "T" => "p:tera", "P" => "p:peta", "E" => "p:exa",
  "Z" => "p:zetta", "Y" => "p:yotta", "R" => "p:ronna", "Q" => "p:quetta",
  "d" => "p:deci", "c" => "p:centi", "m" => "p:milli",
  "µ" => "p:micro", "μ" => "p:micro", "n" => "p:nano", "p" => "p:pico",
  "f" => "p:femto", "a" => "p:atto", "z" => "p:zepto", "y" => "p:yocto",
  "q" => "p:quecto",
}
PREFIX_ORDER = prefix_by_symbol.sort_by { |k, _| -k.length }.to_h

local = YAML.safe_load(File.read("#{REPO}/schema/_units_local.yaml"))
compounds = local["compounds"] || {}
counts = local["counts"] || {}
compounds.each do |id, u|
  Array(u["symbols"]).each do |sym|
    %w[unicode ascii].each { |k| base_map[sym[k]] = id if sym[k].is_a?(String) }
  end
end
counts.each do |id, u|
  Array(u["symbols"]).each do |sym|
    %w[unicode ascii].each { |k| base_map[sym[k]] = id if sym[k].is_a?(String) }
  end
end
poc = compounds["u:percent_of_maximum_capacity"]
if poc
  Array(poc["symbols"]).append({ "unicode" => "% of Max", "ascii" => "% of Max" },
                               { "unicode" => "%Emax", "ascii" => "%Emax" })
end

allowed = Set.new
%w[_units.yaml _units_local.yaml].each do |vf|
  doc = YAML.safe_load(File.read("#{REPO}/schema/#{vf}"))
  %w[units prefixes quantities].each do |k|
    next unless doc[k].is_a?(Hash) && doc[k]["enum"]
    doc[k]["enum"].each { |id| allowed.add(id) }
  end
end
compounds.each_key { |id| allowed.add(id) }
counts.each_key { |id| allowed.add(id) }
symbol_map.each_value { |v| allowed.add(v) }
base_map.each_value { |v| allowed.add(v) }
puts "vocabulary: #{symbol_map.size} aliases + #{base_map.size} base symbols · #{allowed.size} allowed ids"

COUNT_CONVENTIONS = %w[divisions digits DN].freeze
COUNT_IDS = counts.keys.to_set

def resolve(symbol, base_map, prefix_order, allowed)
  s = symbol.strip
  return { unit_id: base_map[s], prefix: nil } if base_map.key?(s)
  stripped = s.sub(/\((g|a|abs|gauge|absolute)\)\z/i, "")
  return { unit_id: base_map[stripped], prefix: nil } if base_map.key?(stripped)
  prefix_order.each do |psym, pid|
    next unless s.start_with?(psym) && s.length > psym.length
    rest = s[psym.length..]
    if base_map.key?(rest) && allowed.include?(base_map[rest])
      return { unit_id: base_map[rest], prefix: pid }
    end
  end
  nil
end

fixed = 0
counted = 0
unresolved = Hash.new(0)
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  y = YAML.unsafe_load_file(f)
  changed = false
  walk = lambda do |node|
    case node
    when Hash
      if node["unit_symbol"].is_a?(String) && node["unit_id"].nil? && !node["unit_symbol"].empty?
        sym = node["unit_symbol"]
        if COUNT_CONVENTIONS.any? { |c| sym.casecmp(c).zero? }
          node["_unit_kind"] = "custom_count"
          counted += 1
          changed = true
        else
          hit = resolve(sym, base_map, PREFIX_ORDER, allowed)
          if hit && hit[:unit_id]
            node["unit_id"] = hit[:unit_id]
            node["prefix"] = hit[:prefix] if hit[:prefix]
            fixed += 1
            changed = true
          else
            unresolved[sym] += 1
          end
        end
      end
      node.each_value { |v| walk.(v) if v.is_a?(Hash) || v.is_a?(Array) }
    when Array
      node.each { |v| walk.(v) if v.is_a?(Hash) || v.is_a?(Array) }
    end
  end
  walk.(y)
  next unless changed
  File.write(f, y.to_yaml(line_width: 100).sub(/\A---\n/, ""))
end
puts "unit_ids backfilled this pass: #{fixed} · counts reclassified as custom_count: #{counted}"
puts "unresolved (top 12): " + unresolved.sort_by { |_k, v| -v }.first(12).map { |k, v| "#{k}=#{v}" }.join(" ")
File.write("#{REPO}/datasets/units-unresolved.json", JSON.pretty_generate(unresolved.sort_by { |_k, v| -v }.to_h))
