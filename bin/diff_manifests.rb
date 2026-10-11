#!/usr/bin/env ruby
# frozen_string_literal: true

# The first real history diff: compares the newest manifest against the
# previous snapshot, one change record per field-level change
# (cert_id, num, field, from, to, observed_at, snapshot pair). New rows and
# vanished rows are recorded as row_added / row_removed. Deterministic,
# regenerable, model-free.

require "json"

REPO = File.expand_path("..", __dir__)
snapshots = Dir.glob("#{REPO}/snapshots/*").map { |d| File.basename(d) }.sort
raise "need at least two snapshots to diff" if snapshots.size < 2
prev_name = snapshots[-2]
curr_name = snapshots[-1]

load = lambda do |name|
  rows = {}
  File.readlines("#{REPO}/snapshots/#{name}/manifest.jsonl").each do |l|
    r = JSON.parse(l)
    rows[r["id"]] = r
  end
  rows
end

prev = load.(prev_name)
curr = load.(curr_name)
changes = []

(prev.keys | curr.keys).sort.each do |id|
  a = prev[id]
  b = curr[id]
  if a && !b
    changes << { "cert_id" => id, "num" => a["num"], "field" => "row", "change" => "row_removed",
                 "from" => nil, "to" => nil, "observed_at" => curr_name,
                 "snapshot_pair" => [prev_name, curr_name], "register_view" => "https://www.oiml.org/en/oiml-cs/certificat_view?certificate=#{(b || a)['num']}" }
    next
  end
  if b && !a
    changes << { "cert_id" => id, "num" => b["num"], "field" => "row", "change" => "row_added",
                 "from" => nil, "to" => nil, "observed_at" => curr_name,
                 "snapshot_pair" => [prev_name, curr_name], "register_view" => "https://www.oiml.org/en/oiml-cs/certificat_view?certificate=#{(b || a)['num']}" }
    next
  end
  # download_status and local_path are this pipeline own bookkeeping, not register facts
  register_fields = a.keys - ["download_status", "local_path"]
  register_fields.each do |field|
    next if a[field] == b[field]
    changes << { "cert_id" => id, "num" => b["num"] || a["num"], "field" => field,
                 "change" => "field_changed", "from" => a[field], "to" => b[field],
                 "observed_at" => curr_name, "snapshot_pair" => [prev_name, curr_name], "register_view" => "https://www.oiml.org/en/oiml-cs/certificat_view?certificate=#{(b || a)['num']}" }
  end
end

require "fileutils"
FileUtils.mkdir_p("#{REPO}/datasets/history")
File.open("#{REPO}/datasets/history/changes.jsonl", "w:UTF-8") do |f|
  changes.each { |c| f.puts(JSON.generate(c)) }
end

by_change = changes.group_by { |c| c["change"] }.transform_values(&:size)
by_field = changes.select { |c| c["change"] == "field_changed" }.group_by { |c| c["field"] }.transform_values(&:size)
puts "diff #{prev_name} -> #{curr_name}: #{changes.size} change records"
puts "  #{by_change.inspect}"
puts "  fields: #{by_field.inspect}" unless by_field.empty?
puts "wrote datasets/history/changes.jsonl"
