#!/usr/bin/env ruby
# frozen_string_literal: true
# Normalize R117 cert YAMLs.

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml/R117/2019"

MEMBER_STATE_MAP = {
  "FR" => "France", "CZ" => "Czech Republic", "NL" => "The Netherlands",
  "DK" => "Denmark", "GB" => "United Kingdom of Great Britain and Northern Ireland",
  "CH" => "Switzerland", "DE" => "Germany",
}

MONTHS = {"january"=>1,"february"=>2,"march"=>3,"april"=>4,"may"=>5,"june"=>6,
          "july"=>7,"august"=>8,"september"=>9,"october"=>10,"november"=>11,"december"=>12}

def parse_date(s)
  return nil unless s.is_a?(String)
  s = s.strip
  return s if s =~ /^\d{4}-\d{2}-\d{2}$/
  if m = s.match(/^(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})$/i)
    day = m[1].to_i
    mon = MONTHS[m[2].downcase] or return nil
    year = m[3].to_i
    return "%04d-%02d-%02d" % [year, mon, day]
  end
  if s =~ /^\d{4}$/
    return s + "-01-01"
  end
  nil
end

fixed = 0
counts = Hash.new(0)

Pathname.glob(YAML_ROOT + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  modified = false

  cert = data["certificate"] || {}
  # 1. Fix scheme
  if cert["scheme"] == "R117"
    cert["scheme"] = "A"
    counts[:scheme] += 1
    modified = true
  end
  # 2. Fix member_state
  ms = cert["member_state"]
  if MEMBER_STATE_MAP.key?(ms)
    cert["member_state"] = MEMBER_STATE_MAP[ms]
    counts[:member_state] += 1
    modified = true
  end
  # 3. Fix date_issued
  di = cert["date_issued"]
  if di.is_a?(String) && di !~ /^\d{4}-\d{2}-\d{2}$/
    new_di = parse_date(di)
    if new_di
      cert["date_issued"] = new_di
      counts[:date] += 1
      modified = true
    end
  end

  # 4. Fill empty recommendation
  rec = data["recommendation"]
  chars = data["characteristics"] || {}
  tl = chars["type_level"] || {}
  if rec.nil? || rec.empty?
    # Try to extract accuracy_class
    ac_val = nil
    if tl["accuracy_class"].is_a?(Hash)
      v = tl["accuracy_class"]["value"]
      ac_val = v.is_a?(Array) ? v : (v ? [v.to_s] : [])
    end
    data["recommendation"] = {
      "id" => "R117",
      "edition" => 2019,
      "amendment" => nil,
      "scheme" => cert["scheme"] || "A",
      "accuracy_classes" => ac_val || []
    }
    counts[:empty_rec] += 1
    modified = true
  elsif rec.is_a?(Hash)
    rec["id"] ||= "R117"
    rec["edition"] ||= 2019
    rec["scheme"] ||= cert["scheme"] || "A"
    rec["accuracy_classes"] ||= []
  end

  # 5. Fix revision_history dates
  (data["revision_history"] || []).each do |r|
    rd = r["date"]
    if rd.is_a?(String) && rd !~ /^\d{4}-\d{2}-\d{2}$/
      new_rd = parse_date(rd)
      if new_rd
        r["date"] = new_rd
        counts[:rev_date] += 1
        modified = true
      end
    end
  end

  # 6. Fix test_report dates
  (data["test_reports"] || []).each do |tr|
    td = tr["date"]
    if td.is_a?(String) && td !~ /^\d{4}-\d{2}-\d{2}$/
      new_td = parse_date(td)
      if new_td
        tr["date"] = new_td
        counts[:tr_date] += 1
        modified = true
      end
    end
  end

  next unless modified
  yp.write(YAML.dump(data))
  fixed += 1
end

puts "Fixed #{fixed} R117 certs"
counts.sort.each { |k, v| puts "  #{k}: #{v}" }
