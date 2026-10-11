#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconciliation layer one: deterministic comparison of the register's own
# fields against each document's statements, for every structured record.
# Verdicts per axis: match | variant (rule-collapsible) | conflict | absent.
# No models here — this sizes the set that needs adjudication.

require "json"
require "yaml"

REPO = File.expand_path("..", __dir__)

LEGAL_EQV = {
  "inc" => "inc", "inc." => "inc", "incorporated" => "inc",
  "ltd" => "ltd", "ltd." => "ltd", "limited" => "ltd",
  "b.v." => "bv", "bv" => "bv",
  "a/s" => "a/s", "a/s." => "a/s",
  "gmbh" => "gmbh", "g.m.b.h." => "gmbh",
  "s.r.o." => "sro", "spol. s r.o." => "sro",
  "co." => "co", "co" => "co", "&" => "and",
}
LEGAL_TOKENS = LEGAL_EQV.keys + %w[kg se ag nv plc sa as srl sarl oy ab holding holdings group]

def norm_name(s)
  s.to_s.gsub(/\s+/, " ").strip.downcase
     .gsub(/[^\p{Word}+]/) { |c| c == "+" ? "+" : " " }
     .gsub(/\S+/) { |w| LEGAL_EQV[w] || w }
     .gsub(/\s+/, " ").strip
end

def norm_num(s)
  n = s.to_s.upcase
       .gsub(/[\s–—]+/, "")        # spaces and typographic dashes only
       .sub(/REV\.?\d+\z/, "")
       .sub(/ANNEX\.?\d+\z/, "")
       .sub(/\AR0+(\d)/, 'R\1')
       .gsub(/-([A-Z])-([A-Z]{2}\d)/, '-\2') # era marker
       .gsub(/([A-Z]{2})\d+-/, '\1-')        # issuer sequence digit (CZ1 == CZ)
  n = n.sub(/-(\d{2})\.(\d+)\z/) do          # serial year 2-digit == 4-digit
    yy = Regexp.last_match(1)
    "-#{yy.to_i < 50 ? "20#{yy}" : "19#{yy}"}.#{Regexp.last_match(2)}"
  end
  n
end

def fold(s)
  s.tr("éèêëàâäáåãçïîíöôóüûúýñšžřćđ", "eeeeaaaaaaciiiooouuynszrcd")
end

def variant_name?(a, b)
  fa = fold(a)
  fb = fold(b)
  return true if fa == fb
  strip = ->(s) { s.split(" ").reject { |w| LEGAL_TOKENS.include?(w) }.join(" ") }
  return true if strip.(fa) == strip.(fb)
  ta = fa.split(" ")
  tb = fb.split(" ")
  return false unless ta.size == tb.size
  ta.each_with_index.all? do |w, i|
    w == tb[i] || (w.size == tb[i].size && (w.chars & tb[i].chars).size >= w.size - 1)
  end
end

manifest = {}
File.readlines("#{REPO}/manifest.jsonl").each do |l|
  r = JSON.parse(l)
  manifest[r["num"]] ||= r
end

counts = Hash.new(0)
out = File.open("#{REPO}/datasets/reconciliation.jsonl", "w:UTF-8")

Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  rel = f.sub(%r{\A#{REPO}/pipeline-work/yaml/}, "").sub(/\.yaml\z/, "")
  y = YAML.unsafe_load_file(f)
  reg = manifest[y.dig("_meta", "num")] || manifest.values.find { |r| r["local_path"] == y.dig("_meta", "source_pdf") }
  next unless reg
  cmp = []

  doc_num = y.dig("certificate", "number")
  if doc_num
    a = norm_num(reg["num"])
    b = norm_num(doc_num)
    verdict = a == b ? "match" : (a.sub(/\/\d{4}-/, "/") == b.sub(/\/\d{4}-/, "/") ? "variant" : "conflict")
    cmp << { "axis" => "num", "register" => reg["num"], "document" => doc_num, "verdict" => verdict }
  end

  doc_appl = y.dig("applicants", 0, "name")
  if doc_appl && reg["applicant"].to_s.size > 0
    a = norm_name(reg["applicant"])
    b = norm_name(doc_appl)
    verdict = a == b ? "match" : (variant_name?(a, b) ? "variant" : "conflict")
    cmp << { "axis" => "applicant", "register" => reg["applicant"], "document" => doc_appl, "verdict" => verdict }
  end

  doc_date = y.dig("certificate", "date_issued")
  if doc_date && reg["issuingYear"]
    doc_year = doc_date.to_s[/\d{4}/]
    verdict = doc_year == reg["issuingYear"].to_s ? "match" : "conflict"
    cmp << { "axis" => "issuing_year", "register" => reg["issuingYear"], "document" => doc_date, "verdict" => verdict }
  end

  num_code = reg["num"].to_s[/-([A-Z]{2}\d+)-/, 1] || reg["num"].to_s[/-[A-Z]-([A-Z]{2}\d+)-/, 1]
  doc_code = y.dig("certificate", "oiml_issuer_id")
  if num_code && doc_code
    verdict = num_code == doc_code.upcase ? "match" : "conflict"
    cmp << { "axis" => "issuer_code", "register" => num_code, "document" => doc_code, "verdict" => verdict }
  end

  overall = if cmp.any? { |c| c["verdict"] == "conflict" } then "conflict"
            elsif cmp.any? { |c| c["verdict"] == "variant" } then "variant"
            else "reconciled"
            end
  counts[overall] += 1
  cmp.each { |c| counts["#{c['axis']}:#{c['verdict']}"] += 1 }
  out.puts(JSON.generate({ "cert_id" => reg["id"], "num" => reg["num"], "record" => rel,
                           "comparisons" => cmp, "overall" => overall }))
end
out.close

puts "reconciliation layer one (deterministic):"
puts "  overall: #{counts['reconciled']} reconciled · #{counts['variant']} variant · #{counts['conflict']} conflict"
puts "  by axis: " + counts.reject { |k, _| %w[reconciled variant conflict].include?(k) }.map { |k, v| "#{k}=#{v}" }.sort.join(" ")
puts "wrote datasets/reconciliation.jsonl"
