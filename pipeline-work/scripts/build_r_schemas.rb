#!/usr/bin/env ruby
# frozen_string_literal: true
# Build proper per-R schemas from observed data + OIML domain knowledge.
#
# Output: schema/R<NN>.yaml — a real Recommendation schema that declares:
#   - recommendation: id, title
#   - certificate_information: pointers to _core.yaml fields
#   - modules_used: which _modules/*.yaml aspect sets apply
#   - scope: per-aspect value constraints (enum values, numeric ranges)
#   - r_specific_aspects: R-only labels not in any module
#
# The previous schema/R<NN>.yaml files (statistics) move to stats/R<NN>.yaml.

require "yaml"
require "pathname"
require "set"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"
SCHEMA_DIR = ROOT + "schema"
MODULES_DIR = SCHEMA_DIR + "_modules"
STATS_DIR = ROOT + "stats"

# ─── Domain knowledge: per-R metadata + accuracy_class value sets ──────

R_TITLES = {
  "R21"  => "Taximeters",
  "R31"  => "Diaphragm gas meters",
  "R46"  => "Active electrical energy meters",
  "R49"  => "Taximeters (older)",
  "R50"  => "Continuous totalising automatic weighing instruments",
  "R51"  => "Automatic gravimetric filling instruments (catchweighers)",
  "R60"  => "Metrological regulation for load cells",
  "R61"  => "Automatic gravimetric filling instruments",
  "R76"  => "Non-automatic weighing instruments",
  "R85"  => "Automatic level measuring instruments",
  "R99"  => "Taximeters (newer)",
  "R105" => "Direct mass flow measurement",
  "R106" => "Automatic weighing instruments",
  "R107" => "Measuring systems for liquids other than water",
  "R111" => "Density measuring instruments",
  "R117" => "Measuring systems for liquids other than water (newer)",
  "R126" => "Ethanol fuel measuring systems",
  "R129" => "Multidimensional measuring instruments",
  "R134" => "Automatic instruments for weighing road vehicles",
  "R136" => "Fuel gas measuring systems",
  "R137" => "Gas meters",
  "R139" => "Fuel dispensers (hydrogen)",
}.freeze

# Per-R accuracy_class enum values (the canonical "allowed set" per Recommendation)
# Derived from OIML Recommendation texts + observed values in certs.
R_ACCURACY_CLASS_ENUM = {
  "R21"  => %w[0.5 1 1.5 2],
  "R31"  => %w[0.5 1 1.5 2],
  "R46"  => %w[A B C],
  "R49"  => %w[0.5 1 1.5],
  "R50"  => %w[I II III IIII],
  "R51"  => %w[I II III IIII Y(a) Y(b)],
  "R60"  => %w[A B C C1 C2 C3 C4 C5 C6 D],
  "R61"  => %w[I II III IIII],
  "R76"  => %w[I II III IIII],
  "R85"  => %w[0.5 1 1.5],
  "R99"  => %w[0.5 1],
  "R105" => %w[0.5 1 1.5 2],
  "R106" => %w[I II III IIII],
  "R107" => %w[0.5 1 1.5 2],
  "R111" => %w[0.5 1],
  "R117" => %w[0.3 0.5 1 1.5 2 5],
  "R126" => %w[0.5 1],
  "R129" => %w[0.5 1 1.5 2],
  "R134" => %w[0.2 0.5 1 2 5 10 B C D E F],
  "R136" => %w[0.5 1 1.5],
  "R137" => %w[0.5 1 1.5 2],
  "R139" => %w[0.6 1 1.5 2 2.5],
}.freeze

# Module membership per R (which aspect modules apply)
# Based on observed data + OIML semantics
R_MODULES = {
  "R21"  => %w[accuracy environmental power_supply software mechanical_speed],
  "R31"  => %w[accuracy flow_metering environmental software],
  "R46"  => %w[accuracy environmental power_supply software],
  "R49"  => %w[accuracy environmental software],
  "R50"  => %w[accuracy environmental flow_metering power_supply software mechanical_speed weighing_capacity],
  "R51"  => %w[accuracy environmental power_supply software mechanical_speed weighing_capacity warmup_adjustment],
  "R60"  => %w[accuracy environmental power_supply software warmup_adjustment],
  "R61"  => %w[accuracy environmental power_supply software weighing_capacity warmup_adjustment],
  "R76"  => %w[accuracy environmental power_supply software weighing_capacity],
  "R85"  => %w[accuracy environmental power_supply software warmup_adjustment],
  "R99"  => %w[accuracy environmental power_supply software warmup_adjustment],
  "R105" => %w[accuracy flow_metering],
  "R106" => %w[accuracy environmental power_supply software mechanical_speed weighing_capacity],
  "R107" => %w[accuracy environmental flow_metering power_supply software weighing_capacity],
  "R111" => %w[accuracy environmental],
  "R117" => %w[accuracy environmental flow_metering power_supply software],
  "R126" => %w[accuracy environmental flow_metering power_supply software warmup_adjustment],
  "R129" => %w[accuracy environmental power_supply software],
  "R134" => %w[accuracy environmental power_supply software mechanical_speed weighing_capacity],
  "R136" => %w[accuracy environmental],
  "R137" => %w[accuracy environmental flow_metering power_supply software],
  "R139" => %w[accuracy environmental flow_metering power_supply software warmup_adjustment],
}.freeze

# ─── Helpers ───────────────────────────────────────────────────────────

def load_modules
  modules = {}
  Pathname.glob(MODULES_DIR + "*.yaml").each do |f|
    data = YAML.safe_load(f.read)
    name = f.basename.to_s.sub(/\.yaml$/, "")
    modules[name] = data
  end
  modules
end

def module_labels_for(modules, module_names)
  labels = []
  module_names.each do |m|
    mod = modules[m]
    next unless mod
    (mod["characteristics"] || {}).keys.each { |l| labels << l }
  end
  labels
end

# Move existing schema/R<NN>.yaml statistics to stats/
def relocate_stats
  STATS_DIR.mkpath
  Pathname.glob(SCHEMA_DIR + "R*.yaml").each do |src|
    next if src.basename.to_s.start_with?("_")
    r = src.basename.to_s.sub(/\.yaml$/, "")
    target = STATS_DIR + "#{r}.yaml"
    FileUtils.mv(src, target) if src.exist?
  end
end

# ─── Build per-R schemas ───────────────────────────────────────────────

def build_r_schema(r_str, modules)
  title = R_TITLES[r_str] || "(unknown)"
  module_names = R_MODULES[r_str] || []
  applicable_labels = Set.new(module_labels_for(modules, module_names))

  # Collect R-specific labels (observed but not in any module)
  r_specific = {}
  if (stats_path = STATS_DIR + "#{r_str}.yaml").exist?
    stats = YAML.safe_load(stats_path.read)
    observed = (stats["type_level_characteristics"] || {}).keys
    observed.each do |label|
      r_specific[label] = { type: "string" } unless applicable_labels.include?(label)
    end
  end

  # Build the schema
  schema = {
    "recommendation" => { "id" => r_str, "title" => title },
    "certificate_information" => {
      "_ref" => "_core.yaml",
      "description" => "Document-level metadata. Every cert has these.",
    },
    "modules_used" => module_names,
    "scope" => {
      "description" => "Per-aspect value constraints defining the valid scope of certificates for this Recommendation",
      "aspects" => {},
    },
  }

  # accuracy_class enum constraint
  if applicable_labels.include?("accuracy_class")
    enum = R_ACCURACY_CLASS_ENUM[r_str]
    schema["scope"]["aspects"]["accuracy_class"] = {
      "type" => "enum_multi",
      "values" => enum,
      "description" => "OIML accuracy class(es) — one or more of the allowed tokens",
    } if enum
  end

  # Other aspects inherit type/unit from their module — R schema only adds constraints
  # when the R narrows them. For now, list which aspects apply.
  applicable_labels.each do |label|
    next if label == "accuracy_class" # already declared
    schema["scope"]["aspects"][label] = { "_inherits_from_module" => true }
  end

  unless r_specific.empty?
    schema["r_specific_aspects"] = r_specific
  end

  schema
end

# ─── Main ──────────────────────────────────────────────────────────────

relocate_stats
modules = load_modules
puts "Loaded #{modules.size} modules: #{modules.keys.sort.join(', ')}"
puts

R_TITLES.keys.each do |r_str|
  schema = build_r_schema(r_str, modules)
  out = SCHEMA_DIR + "#{r_str}.yaml"
  out.write(YAML.dump(schema))
  n_aspects = (schema["scope"]["aspects"] || {}).size
  n_r_spec = (schema["r_specific_aspects"] || {}).size
  puts format("  %-5s  %-50s  %2d modules, %2d aspects, %3d R-specific",
              r_str, R_TITLES[r_str][0,50], schema["modules_used"].size, n_aspects, n_r_spec)
end

puts
puts "Schema files written to: #{SCHEMA_DIR.relative_path_from(ROOT)}/R<NN>.yaml"
puts "Stats moved to:          #{STATS_DIR.relative_path_from(ROOT)}/R<NN>.yaml"
