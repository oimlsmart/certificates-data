#!/usr/bin/env ruby
# frozen_string_literal: true
# Generic normalization across all R-certs: member_state IDs, dates, scheme, empty recommendation.

require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml"

MEMBER_STATE_MAP = {
  "FR" => "France", "CZ" => "Czech Republic", "NL" => "The Netherlands",
  "DK" => "Denmark", "GB" => "United Kingdom of Great Britain and Northern Ireland",
  "CH" => "Switzerland", "DE" => "Germany", "IT" => "Italy", "TR" => "Turkey",
  "CN" => "China", "ES" => "Spain", "US" => "United States", "PL" => "Poland",
  "SE" => "Sweden", "NO" => "Norway", "FI" => "Finland", "BE" => "Belgium",
  "AT" => "Austria", "PT" => "Portugal", "IE" => "Ireland", "GR" => "Greece",
  "SI" => "Slovenia", "HR" => "Croatia", "HU" => "Hungary", "RO" => "Romania",
  "BG" => "Bulgaria", "SK" => "Slovakia", "LT" => "Lithuania", "LV" => "Latvia",
  "EE" => "Estonia", "IS" => "Iceland", "LU" => "Luxembourg", "MT" => "Malta",
  "CY" => "Cyprus",
}

MONTHS = {"january"=>1,"february"=>2,"march"=>3,"april"=>4,"may"=>5,"june"=>6,
          "july"=>7,"august"=>8,"september"=>9,"october"=>10,"november"=>11,"december"=>12}

def parse_date(s)
  return nil unless s.is_a?(String)
  s = s.strip
  return s if s =~ /^\d{4}-\d{2}-\d{2}$/
  if m = s.match(/^(\d{1,2})[\.\s\/]+([A-Za-z]+|\d{1,2})[\.\s\/]+(\d{4})$/i)
    day = m[1].to_i
    mon = MONTHS[m[2].downcase] || m[2].to_i
    year = m[3].to_i
    return nil if mon < 1 || mon > 12
    return "%04d-%02d-%02d" % [year, mon, day]
  end
  if s =~ /^(\d{4})-(\d{1,2})-(\d{1,2})$/
    return "%04d-%02d-%02d" % [$1.to_i, $2.to_i, $3.to_i]
  end
  if s =~ /^\d{4}$/
    return s + "-01-01"
  end
  nil
end

R_EDITIONS = {
  "R46" => 2012, "R51" => 2006, "R85" => 2008, "R137" => 2008,
  "R60" => 2000, "R76" => 2006, "R117" => 2019, "R139" => 2018,
  "R134" => 2006, "R21" => 2007, "R31" => 1995, "R49" => 2006,
  "R50" => 2011, "R61" => 2003, "R99" => 2008, "R105" => 2004,
  "R106" => 2011, "R107" => 2007, "R111" => 2004, "R126" => 1997,
  "R129" => 2000, "R136" => 2002,
}

fixed = 0
counts = Hash.new(0)

Pathname.glob(YAML_ROOT + "R*" + "*" + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  modified = false

  cert = data["certificate"] || {}
  rec_id = data.dig("_meta", "recommendation")
  edition = data.dig("_meta", "edition_year")&.to_i
  rec_key = rec_id ? "#{rec_id.upcase.sub(/^R/, 'R')}" : nil

  # 1. Fix scheme R<NN> → A
  if cert["scheme"].is_a?(String) && cert["scheme"] =~ /^R\d+/
    cert["scheme"] = "A"
    counts[:scheme] += 1
    modified = true
  end

  # 2. Fix member_state ID
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
  if rec.nil? || rec == {}
    if rec_id && edition
      data["recommendation"] = {
        "id" => rec_id, "edition" => edition,
        "amendment" => nil,
        "scheme" => cert["scheme"] || "A",
        "accuracy_classes" => []
      }
      counts[:empty_rec] += 1
      modified = true
    end
  elsif rec.is_a?(Hash)
    if rec_id && rec["id"].nil?
      rec["id"] = rec_id
      modified = true
    end
    if edition && rec["edition"].nil?
      rec["edition"] = edition
      modified = true
    end
    if rec["scheme"].nil?
      rec["scheme"] = cert["scheme"] || "A"
      modified = true
    end
    if rec["accuracy_classes"].nil?
      rec["accuracy_classes"] = []
      modified = true
    end
  end

  # 5. Fix rev history / test report dates
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

puts "Fixed #{fixed} certs across all Rs"
counts.sort.each { |k, v| puts "  #{k}: #{v}" }
