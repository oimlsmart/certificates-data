#!/usr/bin/env ruby
# frozen_string_literal: true

# Finish the PDFs: one glm-5.3-flash vision call per PDF, the verbatim API
# response saved under ocr_raw/ as the permanent source tier. Existing
# successful extractions in ocr_md/ are never re-run and never overwritten.

require "net/http"
require "json"
require "fileutils"
require "open3"
require "optparse"
require "tmpdir"
require "base64"

ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
REPO = File.expand_path("..", __dir__)
RENDER_DPI = 200
READ_TIMEOUT = 600
OPEN_TIMEOUT = 30
MAX_ATTEMPTS = 5
MAX_TOKENS = 16_384

PROMPT = <<~PROMPT
  Transcribe every page of this OIML Certificate of Conformity exactly, as
  GitHub-flavored markdown. Rules:
  - Include ALL text on every page in reading order. Text embedded in images
    (logos, stamps, accuracy-class markings, table scans, signatures) must be
    transcribed too.
  - Reproduce tables as HTML <table> markup.
  - Keep page order; separate pages with a line containing only ---.
  - Do not summarize, translate, annotate, or omit anything. Output the
    transcription only.
PROMPT

options = { workers: 4, limit: nil, family: nil, dry_run: false }
OptionParser.new do |o|
  o.on("--workers N", Integer) { |v| options[:workers] = v }
  o.on("--limit N", Integer) { |v| options[:limit] = v }
  o.on("--family RXXX") { |v| options[:family] = v }
  o.on("--dry-run") { options[:dry_run] = true }
end.parse!

def api_key
  ENV["Z_AI_API_KEY"] || begin
    text = File.read(File.expand_path("~/.zai-api-key")).strip
    text = text.split("=", 2)[1].strip.strip("\"'") if text.start_with?("export ")
    text
  end
end

def api_error?(parsed)
  return true if parsed.is_a?(Hash) && (parsed["error"] || parsed.dig("error", "type"))
  false
end

# Raw responses come in two shapes: the v4 chat/completions shape used until
# 2026-10-06 (choices[0].message.content) and the Anthropic messages shape
# used after (content[] blocks).
def content_of(parsed)
  v4 = parsed.dig("choices", 0, "message", "content")
  return v4 if v4.is_a?(String) && !v4.empty?
  blocks = parsed["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

def successful_md?(md_path)
  return false unless File.exist?(md_path)
  header = File.binread(md_path, 2500).force_encoding("UTF-8").scrub
  !(header =~ /<!-- extraction_method:\s*error\s*-->/)
end

def render_pages(pdf_path, dir)
  stat = Open3.capture3("mutool", "draw", "-r", RENDER_DPI.to_s, "-o", "#{dir}/page-%02d.png", pdf_path.to_s)
  raise "mutool failed for #{pdf_path}: #{stat[1][0, 200]}" unless stat[2].success?
  Dir.glob("#{dir}/page-*.png").sort
end

def call_vision(key, images)
  parts = images.map do |img|
    { type: "image", source: { type: "base64", media_type: "image/png", data: Base64.strict_encode64(File.binread(img)) } }
  end
  parts << { type: "text", text: PROMPT }
  body = { model: MODEL, max_tokens: MAX_TOKENS, messages: [{ role: "user", content: parts }] }.to_json
  last_err = nil
  MAX_ATTEMPTS.times do |attempt|
    begin
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      req["x-api-key"] = key
      req["anthropic-version"] = "2023-06-01"
      req["Content-Type"] = "application/json"
      req.body = body
      res = http.request(req)
      parsed = JSON.parse(res.body)
      # 429 / 1302 rate limits are retriable with backoff, not instant fails
      retryable = res.code.to_i == 429 || parsed.dig("error", "code").to_s == "1302"
      return parsed if res.code.to_i < 500 && !retryable
      last_err = "HTTP #{res.code}: #{res.body[0, 200]}"
    rescue JSON::ParserError
      return { "error" => "non-JSON response" }
    rescue => e
      last_err = e.message
    end
    sleep(2**attempt)
  end
  { "error" => last_err || "exhausted retries" }
end

pdfs = Dir.glob("#{REPO}/certificates/R*/**/*.pdf").sort
pdfs.select! { |p| p =~ %r{/#{Regexp.escape(options[:family])}/} } if options[:family]

targets = []
skipped_done = 0
skipped_raw = 0
pdfs.each do |pdf|
  rel = pdf.delete_prefix("#{REPO}/certificates/").delete_suffix(".pdf")
  raw_path = "#{REPO}/ocr_raw/#{rel}.json"
  if File.exist?(raw_path)
    begin
      JSON.parse(File.read(raw_path))
      skipped_raw += 1
      next
    rescue JSON::ParserError
      # corrupt raw: fall through and re-run
    end
  end
  if successful_md?("#{REPO}/ocr_md/#{rel}.md")
    skipped_done += 1
    next
  end
  targets << [pdf, rel, raw_path]
end
targets = targets.first(options[:limit]) if options[:limit]

warn "PDFs total: #{pdfs.size}; already have raw: #{skipped_raw}; already have md: #{skipped_done}; to extract: #{targets.size}"
exit 0 if targets.empty? || options[:dry_run]
warn "targets#{options[:family] ? " (family #{options[:family]})" : ''}: #{targets.first(3).map { |t| t[1] }.join(', ')} ..."

FileUtils.mkdir_p("#{REPO}/ocr_raw")
manifest_by_path = {}
File.foreach("#{REPO}/manifest.jsonl") do |line|
  row = JSON.parse(line)
  manifest_by_path[row["local_path"]] ||= row if row["local_path"]
end
key = api_key
raise "no API key (Z_AI_API_KEY or ~/.zai-api-key)" if key.to_s.empty?
queue = Queue.new
targets.each { |t| queue << t }
failures = []
mutex = Mutex.new
started = Time.now

workers = Array.new(options[:workers]) do |w|
  Thread.new do
    Thread.current.name = "worker-#{w}"
    loop do
      pdf, rel, raw_path = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      t0 = Time.now
      begin
        Dir.mktmpdir do |dir|
          images = render_pages(pdf, dir)
          raise "no pages rendered for #{pdf}" if images.empty?
          parsed = call_vision(key, images)
          if api_error?(parsed) || content_of(parsed).to_s.empty?
            raise "API error for #{rel}: #{parsed.to_s[0, 300]}"
          end
          FileUtils.mkdir_p(File.dirname(raw_path))
          File.write(raw_path, JSON.pretty_generate(parsed))
          md_path = "#{REPO}/ocr_md/#{rel}.md"
          unless File.exist?(md_path)
            row = manifest_by_path["certificates/#{rel}.pdf"]
            num = row && row["num"].to_s
            issuer = num && (num[/\AR0?\d+\/\d{4}-([A-Z]{2}\d+)-/, 1] || num[/\AR0?\d+\/\d{4}-[A-Z]-([A-Z]{2}\d+)-/, 1])
            FileUtils.mkdir_p(File.dirname(md_path))
            File.write(md_path, <<~MD, mode: "w:UTF-8")
              <!-- cert_id: #{row && row["id"]} -->
              <!-- num: #{num} -->
              <!-- applicant: #{row && row["applicant"]} -->
              <!-- issuing_year: #{row && row["issuingYear"]} -->
              <!-- status: #{row && row["status"]} -->
              <!-- issuer: #{issuer} -->
              <!-- extraction_method: #{MODEL} -->
              <!-- source_pdf: certificates/#{rel}.pdf -->

              #{content_of(parsed)}
            MD
          end
          mutex.synchronize do
            warn format("%s [%05d/%05d] %s (%.1fs, %d pages)", Time.now.strftime("%H:%M:%S"), targets.size - queue.size, targets.size, rel, Time.now - t0, images.size)
          end
        end
      rescue => e
        mutex.synchronize do
          failures << [rel, e.message]
          warn "FAIL #{rel}: #{e.message[0, 300]}"
        end
      end
    end
  end
end
workers.each(&:join)

warn format("done in %.0fs: %d extracted, %d failed", Time.now - started, targets.size - failures.size, failures.size)
unless failures.empty?
  File.write("#{REPO}/ocr_raw/_failures.log", failures.map { |f, m| "#{f}\t#{m.gsub("\n", ' ')}" }.join("\n") + "\n")
  warn "failures logged to ocr_raw/_failures.log"
end
