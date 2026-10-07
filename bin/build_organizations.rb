#!/usr/bin/env ruby
# frozen_string_literal: true

# Build the organizations dataset: issuing authorities, holders (applicants),
# and manufacturers, resolved by the stated normalization rules. Deterministic
# end to end — manifest register surface + extracted-record document surface,
# no models. Regenerates from the tiers on disk.

require "json"
require "yaml"
require "fileutils"

REPO = File.expand_path("..", __dir__)
OUT = "#{REPO}/datasets/organizations/organizations.jsonl"

LEGAL_EQV = {
  "inc" => "inc", "inc." => "inc", "incorporated" => "inc",
  "ltd" => "ltd", "ltd." => "ltd", "limited" => "ltd",
  "b.v." => "bv", "bv" => "bv", "besloten vennootschap" => "bv",
  "a/s" => "a/s", "a/s." => "a/s",
  "gmbh" => "gmbh", "g.m.b.h." => "gmbh",
  "s.r.o." => "sro", "spol. s r.o." => "sro", "spol s r o" => "sro",
  "co." => "co", "co" => "co",
  "&" => "and",
}

def norm_key(name)
  s = name.to_s.gsub(/\s+/, " ").strip.downcase
  s = s.gsub(/[^\p{Word}+]/) { |c| c == "+" ? "+" : " " }
  s = s.gsub(/(\S+)/) { LEGAL_EQV[$1] || $1 }
  s.gsub(/\s+/, " ").strip
end

def slugify(name)
  norm_key(name).delete(" ").tr("+", "-").squeeze("-")[0, 60]
end

manifest = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l) }
manifest_by_num = {}
manifest.each { |r| manifest_by_num[r["num"]] ||= r }

# code -> {names: Hash, countries: Hash, evidence: []} from the extracted tier
# and from every register num's issuer-code segment.
authorities = Hash.new { |h, k| h[k] = { "names" => Hash.new(0), "countries" => Hash.new(0), "evidence" => [] } }
# holder entities by normalization key
holders = Hash.new { |h, k| h[k] = { "names" => Hash.new(0), "addresses" => Hash.new(0), "evidence" => Hash.new(0), "roles" => {} } }
open_questions = []

code_of = lambda do |num|
  num[/\AR0?\d+\/\d{4}-([A-Z]{2}\d+)-/, 1] || num[/\AR0?\d+\/\d{4}-[A-Z]-([A-Z]{2}\d+)-/, 1]
end

Dir["#{REPO}/pipeline-work/yaml/R*/**/*.yaml"].sort.each do |f|
  y = YAML.unsafe_load_file(f)
  num = y.dig("_meta", "num").to_s
  cert_id = y.dig("_meta", "cert_id")
  auth = y["issuing_authority"] || {}
  code = auth["oiml_issuer_id"].to_s
  code = code_of.(num) if code.empty?
  unless code.empty?
    a = authorities[code]
    a["names"][auth["name"]] += 1 unless auth["name"].to_s.empty?
    a["evidence"] << cert_id
  end
  Array(y["applicants"]).each do |p|
    next if p["name"].to_s.empty?
    e = holders[norm_key(p["name"])]
    e["names"][p["name"]] += 1
    e["roles"]["holder"] = true
    e["evidence"][cert_id] = true
    Array(p["address_lines"]).each { |l| e["addresses"][l] += 1 unless l.to_s.empty? }
  end
  Array(y["manufacturers"]).each do |p|
    next if p["name"].to_s.empty?
    e = holders[norm_key(p["name"])]
    e["names"][p["name"]] += 1
    e["roles"]["manufacturer"] = true
    e["evidence"][cert_id] = true
    Array(p["address_lines"]).each { |l| e["addresses"][l] += 1 unless l.to_s.empty? }
  end
end

# register surface: every manifest row's issuer code and applicant string
manifest.each do |row|
  code = code_of.(row["num"].to_s)
  authorities[code]["evidence"] << row["id"] if code
  next if row["applicant"].to_s.strip.empty?
  e = holders[norm_key(row["applicant"])]
  e["names"][row["applicant"]] += 1
  e["roles"]["holder"] = true
  e["evidence"][row["id"]] = true
end

# country for authorities: majority member_state over their certificates
history = {}
File.foreach("#{REPO}/datasets/history/timelines.jsonl") do |l|
  r = JSON.parse(l)
  history[r["num"]] = r.dig("document", "member_state")
end
manifest.each do |row|
  code = code_of.(row["num"].to_s)
  authorities[code]["countries"][history[row["num"]]] += 1 if code && history[row["num"]]
end

# document-vs-register variant detection (G2): for each extracted record whose
# document applicant name differs from the register string, attach the document
# form to the register-keyed entity and flag substantive differences.
Dir["#{REPO}/pipeline-work/yaml/R*/**/*.yaml"].sort.each do |f|
  y = YAML.unsafe_load_file(f)
  num = y.dig("_meta", "num").to_s
  doc_name = y.dig("applicants", 0, "name").to_s
  reg_name = manifest_by_num[num] && manifest_by_num[num]["applicant"].to_s
  next if doc_name.empty? || reg_name.empty?
  next if norm_key(doc_name) == norm_key(reg_name)
  e = holders[norm_key(reg_name)]
  e["names"][doc_name] += 1
  open_questions << { "num" => num, "register" => reg_name, "document" => doc_name,
                      "reason" => norm_key(doc_name).split(/ /) == norm_key(reg_name).split(/ /) ? "suffix/spelling" : "substantive" }
end

slug_used = Hash.new(0)
FileUtils.mkdir_p(File.dirname(OUT))
records = []

authorities.sort.each do |code, a|
  country = a["countries"].sort_by { |_k, v| -v }.first&.first
  records << {
    "id" => "IA-#{code}",
    "kinds" => ["issuing_authority"],
    "oiml_issuer_code" => code,
    "canonical_name" => a["names"].sort_by { |_k, v| -v }.first&.first,
    "name_variants" => a["names"].sort_by { |_k, v| -v }.map { |k, v| { "form" => k, "count" => v, "source" => "document" } },
    "country" => country,
    "notified_body_number" => code == "NO1" ? "0431" : nil,
    "evidence" => { "certificate_count" => a["evidence"].uniq.size, "sample_cert_ids" => a["evidence"].uniq.sort.first(8) },
  }
end
# the one attested notified-body value cites its certificate
records.find { |r| r["id"] == "IA-NO1" }&.[]("evidence")["notified_body_attested_by"] = "R105/1993-NO1-2006.01 (ocr_md/R105/1993/r105-1993-no1-2006-01.md:25)"

holders.sort.each do |key, e|
  slug = "HOLD-#{slugify(key)}"
  slug_used[slug] += 1
  slug = "#{slug}-#{slug_used[slug]}" if slug_used[slug] > 1
  records << {
    "id" => slug,
    "kinds" => e["roles"].keys.sort,
    "oiml_issuer_code" => nil,
    "canonical_name" => e["names"].sort_by { |_k, v| -v }.first.first,
    "name_variants" => e["names"].sort_by { |_k, v| -v }.map { |k, v| { "form" => k, "count" => v, "source" => "mixed" } },
    "country" => nil,
    "address_lines_observed" => e["addresses"].sort_by { |_k, v| -v }.first(6).map { |k, v| { "lines" => k, "count" => v } },
    "notified_body_number" => nil,
    "evidence" => { "certificate_count" => e["evidence"].size, "sample_cert_ids" => e["evidence"].keys.sort.first(8) },
  }
end

File.open(OUT, "w:UTF-8") do |f|
  records.each { |r| f.puts(JSON.generate(r)) }
end
File.write("#{REPO}/datasets/organizations/open-questions.json", JSON.pretty_generate(
  "generated_from" => "register surface (manifest applicant) vs document surface (extracted applicants), G2 of TODO.planes/audit-findings.md",
  "open_questions" => open_questions.uniq { |q| q["num"] },
))

oq = JSON.parse(File.read("#{REPO}/datasets/organizations/open-questions.json"))
oq["nameless_authorities"] = records.select { |r| r["kinds"].include?("issuing_authority") && r["canonical_name"].nil? }.map { |r| r["id"] }
File.write("#{REPO}/datasets/organizations/open-questions.json", JSON.pretty_generate(oq))

auth = records.count { |r| r["kinds"].include?("issuing_authority") }
hold = records.count { |r| r["kinds"].include?("holder") }
mfg = records.count { |r| r["kinds"].include?("manufacturer") }
puts "organizations: #{records.size} (authorities #{auth}, holder-role #{hold}, manufacturer-role #{mfg})"
puts "open questions (document-vs-register variants): #{open_questions.uniq { |q| q['num'] }.size}"
puts "wrote #{OUT}"
