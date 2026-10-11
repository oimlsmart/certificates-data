#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic unit_id backfill: resolve unit_symbol via the unitsdb
# checkout plus the frozen pipeline's alias table (read as data), constrained
# to the schema's closed enums. No models.

require "yaml"

REPO = File.expand_path("..", __dir__)

symbol_map = {}
File.read("#{REPO}/oiml_cs/units/units_db.py").scan(/"([^"]+)":\s*"(u:[^"]+)"/) { |s, id| symbol_map[s] = id }
puts "aliases from the frozen resolver: #{symbol_map.size}"

unitsdb = YAML.safe_load(File.read(File.expand_path("~/src/unitsml/unitsdb/units.yaml")), aliases: true)
(unitsdb["units"] || []).each do |u|
  uid = u["identifiers"].to_a.find { |x| x["id"].to_s.start_with?("u:") }&.dig("id")
  Array(u["symbols"]).each do |sym|
    %w[unicode ascii].each { |k| symbol_map[sym[k]] = uid if sym[k].is_a?(String) && uid }
  end
end
puts "with unitsdb symbols: #{symbol_map.size}"

allowed = {}
%w[_units.yaml _units_local.yaml].each do |vf|
  doc = YAML.safe_load(File.read("#{REPO}/schema/#{vf}"))
  %w[units prefixes quantities].each do |k|
    next unless doc[k].is_a?(Hash) && doc[k]["enum"]
    doc[k]["enum"].each { |id| allowed[id] = true }
  end
end
puts "closed enum: #{allowed.size} ids"

fixed = 0
rejected = 0
unresolved = Hash.new(0)
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  y = YAML.unsafe_load_file(f)
  changed = false
  walk = lambda do |node|
    case node
    when Hash
      if node["unit_symbol"].is_a?(String) && node["unit_id"].nil? && !node["unit_symbol"].empty?
        id = symbol_map[node["unit_symbol"]]
        if id
          if allowed[id]
            node["unit_id"] = id
            fixed += 1
            changed = true
          else
            rejected += 1
          end
        else
          unresolved[node["unit_symbol"]] += 1
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
puts "unit_ids backfilled: #{fixed} · resolved-but-outside-enum skipped: #{rejected}"
puts "unresolved (top 12): " + unresolved.sort_by { |_k, v| -v }.first(12).map { |k, v| "#{k}=#{v}" }.join(" ")
