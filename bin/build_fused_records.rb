#!/usr/bin/env ruby
# frozen_string_literal: true

# Layer three: the fused record — official data + PDF content. For every
# register row: the register's own fields (identity and status are the
# register's), the document's structured sections (the facts are the
# certificate's), and the reconciliation verdicts with the adjudicated
# best values where the two surfaces disagreed. Rows without documents are
# carried as register-only. Deterministic over the tiers; rerun freely.

require "json"
require "yaml"

REPO = File.expand_path("..", __dir__)

manifest = {}
File.readlines("#{REPO}/manifest.jsonl").each do |l|
  r = JSON.parse(l)
  manifest[r["id"]] = r
end

records_by_cert = {}
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  y = YAML.unsafe_load_file(f)
  cid = y.dig("_meta", "cert_id")
  records_by_cert[cid] = { "record" => f.sub(%r{\A#{REPO}/pipeline-work/yaml/}, "").sub(/\.yaml\z/, ""), "y" => y } if cid
end

recon = {}
File.foreach("#{REPO}/datasets/reconciliation.jsonl") do |l|
  r = JSON.parse(l)
  recon[r["cert_id"]] = r
end

adjud = {}
File.foreach("#{REPO}/datasets/adjudications.jsonl") do |l|
  a = JSON.parse(l)
  adjud[a["cert_id"]] = a["axes"]
rescue StandardError
  nil
end

stats = { fused: 0, register_only: 0, axes_adjudicated: 0 }
defects = []
require "fileutils"
FileUtils.mkdir_p("#{REPO}/datasets/certificates")
File.open("#{REPO}/datasets/certificates/records.jsonl", "w:UTF-8") do |out|
  manifest.keys.sort.each do |cid|
    reg = manifest[cid]
    # the register itself sometimes returns defective rows (null num); they
    # cannot be certificate records without identity — state the defect, skip
    if reg["num"].to_s.strip.empty?
      defects << { "cert_id" => cid, "observed" => reg, "defect" => "null num from the register" }
      next
    end
    entry = records_by_cert[cid]
    fused = {
      "cert_id" => cid,
      "register" => {
        "num" => reg["num"], "name" => reg["name"], "applicant" => reg["applicant"],
        "issuing_year" => reg["issuingYear"], "status" => reg["status"],
        "id_status" => reg["idStatus"], "file_name" => reg["fileName"],
        "register_view" => "https://www.oiml.org/en/oiml-cs/certificat_view?certificate=#{reg['num']}",
      },
    }
    if entry
      y = entry["y"]
      fused["document"] = y.reject { |k, _| k == "_meta" }
      fused["provenance"] = {
        "source_pdf" => y.dig("_meta", "source_pdf"),
        "record" => "pipeline-work/yaml/#{entry['record']}.yaml",
        "ocr_raw" => "ocr_raw/#{entry['record']}.json",
        "extract_raw" => "extract_raw/#{entry['record']}.json",
      }
      stats[:fused] += 1
    else
      fused["document"] = nil
      fused["provenance"] = { "register_only" => true }
      stats[:register_only] += 1
    end
    r = recon[cid]
    if r
      axes = r["comparisons"]
      if adjud[cid]
        axes = axes.map do |c|
          a = (adjud[cid] || []).find { |x| x["axis"] == c["axis"] }
          a ? c.merge("adjudication" => a) : c
        end
        stats[:axes_adjudicated] += adjud[cid].size
      end
      fused["reconciliation"] = { "overall" => r["overall"], "axes" => axes }
    end
    out.puts(JSON.generate(fused))
  end
end

File.write("#{REPO}/datasets/certificates/register-defects.json", JSON.pretty_generate(defects)) unless defects.empty?
puts "fused records: #{stats[:fused]} with document · #{stats[:register_only]} register-only · #{stats[:axes_adjudicated]} adjudicated axes"
puts "wrote datasets/certificates/records.jsonl"
