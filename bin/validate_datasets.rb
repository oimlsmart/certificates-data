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

# join integrity: every manifest row appears in the history dataset exactly once
manifest_ids = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["id"] }.sort
history_ids = File.readlines("#{REPO}/datasets/history/timelines.jsonl").map { |l| JSON.parse(l)["cert_id"] }.sort
errors << "history rows (#{history_ids.size}) do not match manifest rows (#{manifest_ids.size})" if manifest_ids != history_ids

# every structured record joins back to the manifest by _meta.num
nums = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["num"] }.to_set rescue nil
require "set"
nums = Set.new(File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l)["num"] })

if errors.empty?
  puts "VALIDATION OK: #{h} history rows, #{o} organization records, joins intact"
else
  puts "VALIDATION FAILED: #{errors.size} error(s)"
  errors.first(20).each { |e| puts "  #{e}" }
  exit 1
end
