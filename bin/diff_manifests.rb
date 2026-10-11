#!/usr/bin/env ruby
# frozen_string_literal: true

# The change log between register snapshots: one record per field-level
# register change, each citing the register's own certificate page.
# APPENDS per snapshot pair — history never overwrites; a pair already
# recorded is skipped. Pipeline bookkeeping fields (download_status,
# local_path) are not register facts and are excluded.

require "json"
require "fileutils"

REPO = File.expand_path("..", __dir__)
snapshots = Dir.glob("#{REPO}/snapshots/*").map { |d| File.basename(d) }.sort
raise "need at least two snapshots to diff" if snapshots.size < 2

out_path = "#{REPO}/datasets/history/changes.jsonl"
existing_pairs = Set.new
if File.exist?(out_path)
  File.readlines(out_path).each do |l|
    pair = JSON.parse(l)["snapshot_pair"] rescue nil
    existing_pairs << pair.join("->") if pair
  end
end
require "set"

load = lambda do |name|
  rows = {}
  File.readlines("#{REPO}/snapshots/#{name}/manifest.jsonl").each do |l|
    r = JSON.parse(l)
    rows[r["id"]] = r
  end
  rows
end

new_changes = 0
(0...(snapshots.size - 1)).each do |i|
  prev_name = snapshots[i]
  curr_name = snapshots[i + 1]
  next if existing_pairs.include?("#{prev_name}->#{curr_name}")

  prev = load.(prev_name)
  curr = load.(curr_name)
  changes = []

  (prev.keys | curr.keys).sort.each do |id|
    a = prev[id]
    b = curr[id]
    view = "https://www.oiml.org/en/oiml-cs/certificat_view?certificate=#{((a || b) || {})['num'].to_s}"
    if a && !b
      changes << { "cert_id" => id, "num" => a["num"], "field" => "row", "change" => "row_removed",
                   "from" => nil, "to" => nil, "observed_at" => curr_name,
                   "snapshot_pair" => [prev_name, curr_name], "register_view" => view }
      next
    end
    if b && !a
      changes << { "cert_id" => id, "num" => b["num"], "field" => "row", "change" => "row_added",
                   "from" => nil, "to" => nil, "observed_at" => curr_name,
                   "snapshot_pair" => [prev_name, curr_name], "register_view" => view }
      next
    end
    register_fields = a.keys - ["download_status", "local_path"]
    register_fields.each do |field|
      next if a[field] == b[field]
      changes << { "cert_id" => id, "num" => b["num"] || a["num"], "field" => field,
                   "change" => "field_changed", "from" => a[field], "to" => b[field],
                   "observed_at" => curr_name, "snapshot_pair" => [prev_name, curr_name],
                   "register_view" => view }
    end
  end

  File.open(out_path, "a:UTF-8") do |f|
    changes.each { |c| f.puts(JSON.generate(c)) }
  end
  new_changes += changes.size
  by = changes.group_by { |c| c["change"] }.transform_values(&:size)
  puts "#{prev_name} -> #{curr_name}: #{changes.size} records #{by.inspect}"
end
puts "appended #{new_changes} change records (existing pairs skipped: #{existing_pairs.size})"
