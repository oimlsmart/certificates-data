#!/usr/bin/env ruby
# frozen_string_literal: true

# Build the per-certificate history dataset: every manifest row joined with
# the document-stated facts extractable deterministically from the ocr_md
# tier (revision tables, issue date, member state, supersession statements).
# No model is called; the whole file regenerates from the tiers on disk.

require "json"
require "fileutils"

REPO = File.expand_path("..", __dir__)
OUT = "#{REPO}/datasets/history/timelines.jsonl"

# English full names and abbreviations, plus the German and Croatian month
# forms observed in the corpus (märz, mai, maj, juni, juli, oktober, ...).
MONTH_NUM = {}
%w[january february march april may june july august september october november december]
  .each_with_index { |m, i| MONTH_NUM[m] = i + 1 }
%w[jan feb mar apr may jun jul aug sep oct nov dec]
  .each_with_index { |m, i| MONTH_NUM[m] = i + 1 }
{
  "januar" => 1, "februar" => 2, "märz" => 3, "maerz" => 3, "mai" => 5,
  "juni" => 6, "juli" => 7, "oktober" => 10, "dezember" => 12,
  "maj" => 5, "sijecanj" => 1, "veljaca" => 2, "ozujak" => 3, "travanj" => 4,
  "svibanj" => 5, "lipanj" => 6, "srpanj" => 7, "kolovoz" => 8, "rujan" => 9,
  "listopad" => 10, "studeni" => 11, "prosinac" => 12,
}.each { |m, i| MONTH_NUM[m] = i }
MONTH_ALT = MONTH_NUM.keys.sort_by { |k| -k.length }.join("|")
ENTITY = { "&nbsp;" => " ", "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"', "&#39;" => "'" }

def clean(text)
  ENTITY.each { |k, v| text = text.gsub(k, v) }
  text.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
end

def month_num(name)
  MONTH_NUM[name.downcase.gsub(/[.\s]/, "").sub("sept", "sep")]
end

def parse_date(raw)
  s = clean(raw.to_s)
  return nil if s.empty?
  return s[/\d{4}-\d{2}-\d{2}/] if s =~ /\d{4}-\d{2}-\d{2}/
  if (m = s.match(/(\d{1,2})\.(\d{1,2})\.(\d{4})/))
    return format("%04d-%02d-%02d", m[3].to_i, m[2].to_i, m[1].to_i)
  end
  if (m = s.match(/(\d{1,2})(?:st|nd|rd|th)?\.?\s+(#{MONTH_ALT})\.?,?\s+(\d{4})/i))
    return format("%04d-%02d-%02d", m[3].to_i, month_num(m[2]) || 0, m[1].to_i)
  end
  if (m = s.match(/(#{MONTH_ALT})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\.?,?\s+(\d{4})/i))
    return format("%04d-%02d-%02d", m[3].to_i, month_num(m[1]) || 0, m[2].to_i)
  end
  nil
end


def date_issued_line(body)
  lines = body.each_line.map { |l| l.force_encoding("UTF-8").scrub }
  patterns = [
    /^\s*\#{0,6}\s*\**\s*issue date:?\s*\**\s*(.+)$/i,
    /^\s*\#{0,6}\s*\**\s*date of issue:?\s*\**\s*(.+)$/i,
    /^\s*\#{0,6}\s*\**\s*date issued:?\s*\**\s*(.+)$/i,
    /oiml issuing authority\s+[a-z]{2}\d\s+(.+)$/i,
    /^\s*\#{0,6}\s*\**\s*issued on[:\s]+(.+)$/i,
    /^\s*\#{0,6}\s*\**\s*dated:?\s+(.+)$/i,
    /^\s*\#{0,6}\s*\**\s*date:?\s+(.+)$/i,
  ]
  patterns.each do |re|
    lines.each do |line|
      return clean($1) if line =~ re
    end
  end
  nil
end

def member_state_line(body)
  labels = [
    /^\s*\#{0,6}\s*(?:\*\*)?\s*oiml member state\b[:\s]*(.*)$/i,
    /^\s*(?:\*\*)?\s*member state of oiml\b[:\s]*(.*)$/i,
  ]
  lines = body.each_line.map { |l| l.force_encoding("UTF-8").scrub }
  lines.each_with_index do |line, i|
    labels.each do |re|
      next unless (m = line.match(re))
      value = clean(m[1]).gsub("*", "").strip
      next if value =~ /^in which\b/i
      return value unless value.empty?
      # the label often stands alone with the state on the following line
      follow = lines[(i + 1)..(i + 3)].to_a.map { |l| clean(l).gsub("*", "").strip }.reject(&:empty?).first
      return follow if follow && follow.length <= 60 && follow !~ /important note|page=/i
    end
  end
  nil
end

def parse_tables(body)
  body.to_s.scan(/<table[^>]*>(.*?)<\/table>/mi).map { |t| t[0] }.map do |tbl|
    tbl.scan(/<tr[^>]*>(.*?)<\/tr>/mi).map do |tr|
      tr[0].scan(/<t[dh][^>]*>(.*?)<\/t[dh]>/mi).map { |c| clean(c[0]) }
    end
  end
end

def revision_history(body)
  out = []
  parse_tables(body).each do |rows|
    next unless rows.first && rows.first.first.to_s =~ /^rev(ision|\.?)$/i
    header = rows.first
    date_idx = header.index { |c| c =~ /^date/i }
    change_idx = header.index { |c| c =~ /^change|modification|description|object/i }
    rows.drop(1).each do |cells|
      next if cells.empty?
      rev = cells[0]
      date_raw = date_idx ? cells[date_idx] : nil
      changes = change_idx ? cells[change_idx] : cells[1..].compact.join("; ")
      out << { "revision" => rev, "date_raw" => date_raw, "date_iso" => parse_date(date_raw.to_s), "changes" => changes.to_s.empty? ? nil : changes }
    end
  end
  out
end

def supersession_statements(body)
  body.to_s.scan(/[^.\n]{0,120}\b(?:supersedes?|replaces the previous (?:version|revision|one))/i)
      .map { |s| clean(s)[0, 200] }.reject { |s| s.empty? || s.length < 8 }.uniq
end

manifest_rows = File.readlines("#{REPO}/manifest.jsonl").map { |l| JSON.parse(l) }
md_by_path = {}
Dir.glob("#{REPO}/ocr_md/R*/**/*.md").sort.each do |md|
  next if md =~ /backup/
  rel = md.delete_prefix("#{REPO}/ocr_md/").delete_suffix(".md")
  md_by_path["certificates/#{rel}.pdf"] = md
end
snapshot = Dir.glob("#{REPO}/snapshots/*").map { |d| File.basename(d) }.sort.last

stats = Hash.new(0)
FileUtils.mkdir_p(File.dirname(OUT))
File.open(OUT, "w:UTF-8") do |f|
  manifest_rows.each do |row|
    num = row["num"].to_s
    rec = {
      "cert_id" => row["id"],
      "num" => num,
      "recommendation" => num[/\AR0?(\d+)\//] ? "R#{$1}" : nil,
      "num_revision" => num[/ Rev\. (\d+)\z/, 1],
      "num_annex" => num[/ Annex\. (\d+)\z/, 1],
      "register" => {
        "issuing_year" => row["issuingYear"],
        "status" => row["status"],
        "id_status" => row["idStatus"],
        "observed_at" => snapshot,
      },
      "document" => nil,
    }
    md = md_by_path[row["local_path"].to_s]
    if md
      body = File.binread(md).force_encoding("UTF-8").scrub
      header = body[0, 2500]
      raw_date = date_issued_line(body)
      rec["document"] = {
        "source_md" => md.delete_prefix("#{REPO}/"),
        "extraction_method" => header[/<!-- extraction_method:\s*(.*?)\s*-->/, 1],
        "date_issued_raw" => raw_date,
        "date_issued_iso" => parse_date(raw_date.to_s),
        "member_state" => member_state_line(body),
        "replaces_previous_version" => !supersession_statements(body).empty?,
        "supersession_statements" => supersession_statements(body),
        "revision_history" => revision_history(body),
      }
    end
    %w[num register].each { |k| raise "missing #{k} in #{row['id']}" if rec[k].nil? }
    f.puts(JSON.generate(rec))

    stats[:rows] += 1
    if rec["document"]
      stats[:with_document] += 1
      stats[:date_issued] += 1 if rec["document"]["date_issued_raw"]
      stats[:date_iso] += 1 if rec["document"]["date_issued_iso"]
      stats[:member_state] += 1 if rec["document"]["member_state"]
      stats[:revision_history] += 1 unless rec["document"]["revision_history"].empty?
      stats[:replaces] += 1 if rec["document"]["replaces_previous_version"]
    end
  end
end

puts "rows: #{stats[:rows]} (snapshot observed_at: #{snapshot})"
puts "with document: #{stats[:with_document]}"
puts "  date_issued raw/iso: #{stats[:date_issued]} / #{stats[:date_iso]}"
puts "  member_state: #{stats[:member_state]}"
puts "  revision_history non-empty: #{stats[:revision_history]}"
puts "  replaces-previous statements: #{stats[:replaces]}"
puts "wrote #{OUT}"
