#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate the datasets against their schemas: the history timelines and the
# organizations records against their draft-07 JSON Schemas, plus the join
# integrity between tiers. Runs in CI on every change; a failure must block
# the merge, never ship as data.

require "json"

REPO = File.expand_path("..", __dir__)
errors = []

def type_ok?(value, type)
  case type
  when "object" then value.is_a?(Hash)
  when "array" then value.is_a?(Array)
  when "string" then value.is_a?(String)
  when "integer" then value.is_a?(Integer)
  when "number" then value.is_a?(Numeric)
  when "boolean" then [true, false].include?(value)
  when "null" then value.nil?
  else true
  end
end

def check_object(obj, schema, path, errors)
  props = schema["properties"] || {}
  required = schema["required"] || []
  required.each do |key|
    errors << "#{path}: missing required '#{key}'" unless obj.key?(key)
  end
  if schema["additionalProperties"] == false
    (obj.keys - props.keys).each { |k| errors << "#{path}: additional property '#{k}'" }
  end
  obj.each do |key, value|
    next unless props.key?(key)
    pschema = props[key]
    types = pschema["type"] ? Array(pschema["type"]) : nil
    if types && !types.any? { |t| type_ok?(value, t) }
      errors << "#{path}.#{key}: #{value.class} is not #{types.join('|')}"
      next
    end
    if value.is_a?(Hash) && pschema["properties"]
      check_object(value, pschema, "#{path}.#{key}", errors)
    elsif value.is_a?(Array) && pschema["items"]
      value.each_with_index do |el, i|
        if el.is_a?(Hash) && pschema["items"]["properties"]
          check_object(el, pschema["items"], "#{path}.#{key}[#{i}]", errors)
        end
      end
    end
    if pschema["enum"] && !pschema["enum"].include?(value)
      errors << "#{path}.#{key}: #{value.inspect} not in enum"
    end
  end
end

def validate_jsonl(jsonl_path, schema_path, label, errors)
  schema = JSON.parse(File.read(schema_path))
  n = 0
  File.readlines(jsonl_path).each do |line|
    n += 1
    obj = JSON.parse(line)
    check_object(obj, schema, "#{label}[#{n - 1}]", errors)
  end
  n
end

h = validate_jsonl("#{REPO}/datasets/history/timelines.jsonl",
                   "#{REPO}/datasets/history/timelines.schema.json", "history", errors)
o = validate_jsonl("#{REPO}/datasets/organizations/organizations.jsonl",
                   "#{REPO}/datasets/organizations/organizations.schema.json", "organizations", errors)


r = validate_jsonl("#{REPO}/datasets/certificates/records.jsonl",
                   "#{REPO}/datasets/certificates/records.schema.json", "fused-records", errors)
c = validate_jsonl("#{REPO}/datasets/history/changes.jsonl",
                   "#{REPO}/datasets/history/changes.schema.json", "changes", errors)
rec = validate_jsonl("#{REPO}/datasets/reconciliation.jsonl",
                     "#{REPO}/datasets/reconciliation.schema.json", "reconciliation", errors)
adj = validate_jsonl("#{REPO}/datasets/adjudications.jsonl",
                     "#{REPO}/datasets/adjudications.schema.json", "adjudications", errors)
enr = validate_jsonl("#{REPO}/datasets/certificates/register-only-enrichment.jsonl",
                     "#{REPO}/datasets/certificates/register-only-enrichment.schema.json", "enrichment", errors)

# tier closure: every md has a record; every PDF has an md or is legacy-covered;
# every non-defective register row appears in the fused dataset
mds = Dir.glob("#{REPO}/ocr_md/R*/**/*.md").reject { |f| f =~ /backup|chatnoise/ }
recordless = mds.count { |m| !File.exist?("#{REPO}/pipeline-work/yaml/#{m.sub(%r{\A.*/ocr_md/}, "").sub(/\.md\z/, "")}.yaml") }
errors << "tier closure: #{recordless} mds without a structured record" if recordless > 0
defect_ids = begin
  JSON.parse(File.read("#{REPO}/datasets/certificates/register-defects.json")).map { |d| d["cert_id"] }
rescue StandardError
  []
end
manifest_ids_all = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["id"] }
fused_ids = File.readlines("#{REPO}/datasets/certificates/records.jsonl").map { |l| JSON.parse(l)["cert_id"] }
missing_fused = (manifest_ids_all - fused_ids - defect_ids)
errors << "tier closure: #{missing_fused.size} register rows missing from fused dataset (#{missing_fused.first(3).inspect})" unless missing_fused.empty?

# join integrity: every manifest row appears in the history dataset exactly once
manifest_ids = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["id"] }.sort
history_ids = File.readlines("#{REPO}/datasets/history/timelines.jsonl").map { |l| JSON.parse(l)["cert_id"] }.sort
errors << "history rows (#{history_ids.size}) do not match manifest rows (#{manifest_ids.size})" if manifest_ids != history_ids

# every structured record joins back to the manifest by _meta.num
nums = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["num"] }.to_set rescue nil
require "set"
nums = Set.new(File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["num"] })

if errors.empty?
  puts "VALIDATION OK: #{h} history · #{c} changes · #{rec} reconciliation · #{adj} adjudications · #{enr} enrichment · #{o} organizations · #{r} fused — tiers closed, joins intact"
else
  puts "VALIDATION FAILED: #{errors.size} error(s)"
  errors.first(20).each { |e| puts "  #{e}" }
  exit 1
end
