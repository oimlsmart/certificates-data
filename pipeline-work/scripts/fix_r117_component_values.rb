#!/usr/bin/env ruby
# frozen_string_literal: true

# Fix Category E (66 entries): malformed component.characteristics in R117
# where `value:` holds a hash containing nested `values:` array.
#
# Before (malformed):
#   flow_rate_range:
#     value:
#       unit_symbol: L/min
#       values:
#         - model: C+
#           value: {min: 1.6, max: 40}
#         - model: V
#           value: {min: 1.6, max: 40}
#       unit_id: u:liter_per_minute
#
# After (canonical — MapValue keyed by model):
#   flow_rate_range:
#     value:
#       C+: {min: 1.6, max: 40}
#       V:  {min: 1.6, max: 40}
#     unit_symbol: L/min
#     unit_id: u:liter_per_minute

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"

fixed_total = 0
files_changed = 0

Pathname.glob(YAML_ROOT + "R117" + "*" + "*.yaml").sort.each do |yp|
  cert = YAML.safe_load(File.read(yp), permitted_classes: [Date, Time, Symbol])
  next unless cert.is_a?(Hash)

  changed = false

  walk = lambda do |node|
    case node
    when Hash
      node.each_value { |v| walk.call(v) }
    when Array
      node.each { |v| walk.call(v) }
    end
  end

  fix_in_hash = lambda do |h|
    h.each do |_key, val|
      case val
      when Hash
        # Recurse first
        fix_in_hash.call(val)
        # Then check this hash's own values for malformed subhashes
        val.each do |k, v|
          next unless v.is_a?(Hash)
          next unless v.key?("value") && v["value"].is_a?(Hash) && v["value"].key?("values")

          # Found malformed: lift unit_symbol/unit_id out, convert values → MapValue
          inner = v["value"]
          unit_symbol = inner["unit_symbol"]
          unit_id = inner["unit_id"]
          model_entries = inner["values"]

          map_value = {}
          model_entries.each do |entry|
            model = entry["model"] || entry["variant"] || entry["class"]
            next unless model
            map_value[model.to_s] = entry["value"]
          end

          # Replace in-place
          val[k] = {
            "value" => map_value,
            "unit_symbol" => unit_symbol,
            "unit_id" => unit_id,
          }.compact
          fixed_total += 1
          changed = true
          # Recurse into the new structure in case of nested issues
          fix_in_hash.call(val[k])
        end
      when Array
        val.each { |x| fix_in_hash.call(x) if x.is_a?(Hash) }
      end
    end
  end

  fix_in_hash.call(cert)
  next unless changed

  File.write(yp, YAML.dump(cert, line_width: 120))
  files_changed += 1
end

warn "Fixed #{fixed_total} malformed entries across #{files_changed} files"
