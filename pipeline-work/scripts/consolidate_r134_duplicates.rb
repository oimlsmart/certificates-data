#!/usr/bin/env ruby
# frozen_string_literal: true
# Consolidate duplicate fields in R134 cert YAMLs.
# GLM extractor produced many label variants for the same concept.
# This script keeps canonical labels and merges values.

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml/R134/2006"

# Map: deprecated label → canonical label
# (canonical labels align with schema/_modules/*.yaml where possible)
DEDUP = {
  "verification_scale_interval_d" => "scale_interval",
  "scale_interval_t" => "scale_interval",  # only when value+unit matches; otherwise keep

  "max_gvw" => "maximum_capacity_gvw",
  "min_gvw" => "minimum_capacity_gvw",
  "max_axle" => "maximum_capacity_axle",
  "min_axle" => "minimum_capacity_axle",
  "maximum_capacity_axle_load_max" => "maximum_capacity_axle_load",
  "minimum_capacity_axle_load_min" => "minimum_capacity_axle_load",
  "maximum_capacity_axle_max" => "maximum_capacity_axle",
  "minimum_capacity_axle_min" => "minimum_capacity_axle",
  "maximum_capacity_vehicle_mass" => "maximum_capacity_vehicle",
  "minimum_capacity_vehicle_mass" => "minimum_capacity_vehicle",
  "maximum_capacity_totalized" => "maximum_capacity_gvw_totalized",
  "minimum_capacity_totalized" => "minimum_capacity_gvw_totalized",

  "maximum_number_of_axles_a_max" => "maximum_number_of_axles_per_vehicle",
  "maximum_number_of_axles_per_vehicle_a_max" => "maximum_number_of_axles_per_vehicle",
  "max_number_of_axles_a_max" => "maximum_number_of_axles_per_vehicle",
  "max_number_of_axles" => "maximum_number_of_axles_per_vehicle",

  "maximum_speed" => "maximum_operating_speed_vmax",
  "minimum_speed" => "minimum_operating_speed_vmin",
  "maximum_operating_speed_nu_max" => "maximum_operating_speed_vmax",
  "minimum_operating_speed_nu_min" => "minimum_operating_speed_vmin",
  "maximum_operation_speed" => "maximum_operating_speed_vmax",
  "minimum_operation_speed" => "minimum_operating_speed_vmin",

  "electrical_power_supply_voltage" => "power_supply_voltage",
  "electrical_power_supply_frequency" => "power_supply_frequency",

  "accuracy_class_for_vehicle_mass" => "accuracy_class_vehicle_mass",
  "accuracy_class_for_axle_load" => "accuracy_class_axle_load",
  "accuracy_class_for_axle_group_load" => "accuracy_class_axle_group_load",
  "accuracy_class_total_vehicle_mass" => "accuracy_class_vehicle_mass",
  "accuracy_class_total_weight" => "accuracy_class_vehicle_mass",
  "accuracy_class_single_axle_loads" => "accuracy_class_axle_load",
  "accuracy_class_single_axle_load" => "accuracy_class_axle_load",

  "scale_intervals" => "number_of_scale_intervals",
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

def merge_prefer_existing(canonical_vobj, dup_vobj)
  # Prefer existing canonical value. If canonical missing, use dup.
  return canonical_vobj unless canonical_vobj.nil?
  dup_vobj
end

fixed = 0
counts = Hash.new(0)

Pathname.glob(YAML_ROOT + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  data = stringify_keys(data)
  modified = false

  chars = data["characteristics"]
  next unless chars.is_a?(Hash)
  tl = chars["type_level"]
  next unless tl.is_a?(Hash)

  DEDUP.each do |old_label, new_label|
    next unless tl.key?(old_label)
    dup = tl.delete(old_label)
    counts[old_label] += 1
    modified = true
    if tl.key?(new_label)
      # Both exist; keep canonical
      merged = merge_prefer_existing(tl[new_label], dup)
      tl[new_label] = merged if merged
    else
      tl[new_label] = dup
    end
  end

  next unless modified
  yp.write(YAML.dump(data))
  fixed += 1
end

puts "Consolidated duplicates in #{fixed} R134 certs"
counts.sort.each { |k, v| puts "  #{k}: #{v}" }
