#!/usr/bin/env ruby
# frozen_string_literal: true
require "yaml"
require "json_schemer"
require "pathname"

ROOT       = Pathname.new(File.expand_path("..", __dir__))
SCHEMA_DIR = ROOT / "schema"
YAML_DIR   = ROOT / "yaml"

# Strip https://oimlsmart.org/schemas/ (or any host) and any duplicated _modules/ prefix.
def normalize_ref(ref)
  path = ref.to_s
  path = path.sub(%r{^https?://[^/]+(/schemas)?/}, "")
  path = path.sub(%r{^_modules/_modules/}, "_modules/")
  # Some refs land as "_modules/_core.yaml" because d011_environmental.yaml is
  # in _modules/ and refs resolve relative to its location. The canonical files
  # _core.yaml and _units.yaml live directly under schema/, not under _modules/.
  path = path.sub(%r{^_modules/(_core|_units)\.yaml$}, '\1.yaml')
  path
end

SCHEMA_FILE_CACHE = Hash.new do |h, ref_key|
  path = normalize_ref(ref_key)
  full = SCHEMA_DIR.join(path)
  next h[ref_key] = nil unless full.exist?
  h[ref_key] = YAML.safe_load(File.read(full), aliases: true,
                              permitted_classes: [Date, Time, Symbol])
end

def build_schemer(r_schema_filename)
  schema = SCHEMA_FILE_CACHE[r_schema_filename]
  raise "R schema not found: #{r_schema_filename}" unless schema

  JSONSchemer.schema(
    schema,
    ref_resolver: lambda do |ref|
      target = SCHEMA_FILE_CACHE[ref]
      if target.nil?
        warn "  [ref_resolver] cannot find #{normalize_ref(ref)} for ref #{ref}"
        next nil
      end
      target
    end
  )
end

def validate_recommendation(rname)
  num = rname.sub(/^R/, "")
  schema_file = "R#{num}.yaml"
  return { skipped: "no schema #{schema_file}" } unless SCHEMA_FILE_CACHE[schema_file]

  schemer = build_schemer(schema_file)

  cert_dir = YAML_DIR.join("R#{num}")
  return { skipped: "no cert dir R#{num}" } unless cert_dir.exist?

  cert_files = Dir.glob(cert_dir.join("**", "*.yaml")).sort
  total_errors = 0
  certs_with_errors = 0

  cert_files.each do |cert_path|
    abs = File.expand_path(cert_path)
    cert = YAML.safe_load(File.read(abs), permitted_classes: [Date, Time, Symbol])
    errors = schemer.validate(cert).to_a
    next if errors.empty?
    certs_with_errors += 1
    total_errors += errors.length
    rel = Pathname.new(abs).relative_path_from(ROOT)
    puts "\n#{rel} (#{errors.length} errors)"
    errors.first(8).each do |e|
      data_path   = e["data_pointer"] || "<root>"
      schema_path = e["schema_pointer"]
      puts "  data=#{data_path}  schema=#{schema_path}  #{e.fetch("error", "")}"
    end
    puts "  ... +#{errors.length - 8} more" if errors.length > 8
  rescue => e
    certs_with_errors += 1
    total_errors += 1
    warn "  #{File.basename(cert_path)}: #{e.class}: #{e.message[0..200]}"
  end

  { certs: cert_files.length, errors: total_errors, certs_with_errors: certs_with_errors }
end

rs = ARGV.empty? ? Dir.glob(SCHEMA_DIR.join("R*.yaml")).map { |p| File.basename(p, ".yaml") }.sort : ARGV

total_certs = 0
total_errors = 0
rs.each do |r|
  result = validate_recommendation(r)
  if result[:skipped]
    STDERR.puts "#{r}: skipped — #{result[:skipped]}"
    next
  end
  total_certs += result[:certs]
  total_errors += result[:errors]
  STDERR.puts "#{r}: #{result[:certs]} certs, #{result[:certs_with_errors]} with errors, #{result[:errors]} total errors"
end

STDERR.puts "\nTotal: #{total_certs} certs, #{total_errors} errors across #{rs.length} recommendations"
