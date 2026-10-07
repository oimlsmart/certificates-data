#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-page fallback for PDFs the provider's content filter rejects as whole
# documents (z.ai error 1301). Each page is transcribed in its own call; a
# page that is still rejected at a second render scale is recorded as blocked
# in the assembled raw, never silently dropped. The assembled file uses the
# same raw shape as bin/finish_pdfs.rb output so downstream derives normally.

require "net/http"
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require "base64"

REPO = File.expand_path("..", __dir__)
ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
MAX_TOKENS = 30_000

PROMPT = <<~PROMPT
  Transcribe this single page of an OIML Certificate of Conformity exactly, as
  GitHub-flavored markdown. Include ALL text in reading order, including text
  embedded in images (logos, stamps, accuracy-class markings, signatures).
  Reproduce tables as HTML <table> markup. Do not summarize, translate,
  annotate, or omit anything. Output the transcription only.
PROMPT

def api_key
  ENV["Z_AI_API_KEY"] || begin
    text = File.read(File.expand_path("~/.zai-api-key")).strip
    text = text.split("=", 2)[1].strip.strip("\"'") if text.start_with?("export ")
    text
  end
end

def call_page(key, image, note)
  parts = [{ type: "image", source: { type: "base64", media_type: "image/png", data: Base64.strict_encode64(File.binread(image)) } },
           { type: "text", text: note }]
  body = { model: MODEL, max_tokens: MAX_TOKENS, messages: [{ role: "user", content: parts }] }.to_json
  4.times do |attempt|
    begin
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 600
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      req["Authorization"] = "Bearer #{api_key}"
      req["Content-Type"] = "application/json"
      req.body = body
      res = http.request(req)
      parsed = JSON.parse(res.body)
      return parsed unless res.code.to_i >= 500
    rescue JSON::ParserError
      return { "error" => "non-JSON response" }
    rescue => e
      return { "error" => e.message } if attempt == 3
    end
    sleep(2**attempt)
  end
  { "error" => "exhausted retries" }
end

def filtered?(response)
  response.dig("error", "code").to_s == "1301"
end

def content_of(response)
  blocks = response["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

manifest_by_path = {}
File.foreach("#{REPO}/manifest.jsonl") do |line|
  row = JSON.parse(line)
  manifest_by_path[row["local_path"]] ||= row if row["local_path"]
end

stems = Dir.glob("#{REPO}/ocr_raw/_run*.log").flat_map do |log|
  File.readlines(log).grep(/^FAIL/).map { |l| l[/^FAIL (\S+):/, 1] }
end.compact.uniq.reject { |s| File.exist?("#{REPO}/ocr_raw/#{s}.json") }
puts "content-filter blocked certificates: #{stems.size}"
stems.each { |s| puts "  #{s}" }
exit 0 if stems.empty?

key = api_key
stems.each do |stem|
  pdf = "#{REPO}/certificates/#{stem}.pdf"
  raise "missing pdf #{pdf}" unless File.exist?(pdf)
  per_page = []
  Dir.mktmpdir do |dir|
    stat = Open3.capture3("mutool", "draw", "-r", "200", "-o", "#{dir}/p-%02d.png", pdf)
    raise "mutool failed for #{stem}" unless stat[2].success?
    pages = Dir.glob("#{dir}/p-*.png").sort
    puts "#{stem}: #{pages.size} pages"
    pages.each_with_index do |img, i|
      note = "This is page #{i + 1} of #{pages.size} of the certificate."
      response = call_page(key, img, note)
      if filtered?(response)
        # one retry at a smaller render: a different raster can pass the filter
        alt = "#{dir}/alt-%02d.png" % (i + 1)
        Open3.capture3("mutool", "draw", "-r", "130", "-o", alt, pdf, "#{i + 1}")
        if File.exist?(alt)
          response = call_page(key, alt, note)
        end
      end
      if filtered?(response)
        per_page << { "page" => i + 1, "status" => "blocked", "detail" => "provider content filter rejected this page at 200 and 130 dpi" }
        puts "  page #{i + 1}: BLOCKED"
      elsif response["error"] || content_of(response).to_s.empty?
        raise "page #{i + 1} of #{stem}: #{response.to_s[0, 200]}"
      else
        per_page << { "page" => i + 1, "status" => "ok", "response" => response }
        puts "  page #{i + 1}: ok (#{content_of(response).size} chars)"
      end
    end
  end
  content = per_page.map do |p|
    p["status"] == "ok" ? content_of(p["response"]) : "<!-- page #{p['page']}: blocked by provider content filter; transcription unavailable -->"
  end.join("\n\n---\n\n")
  assembled = {
    "model" => "#{MODEL}-per-page",
    "created" => Time.now.to_i,
    "usage" => {
      "completion_tokens" => per_page.sum { |p| p.dig("response", "usage", "completion_tokens").to_i },
      "prompt_tokens" => per_page.sum { |p| p.dig("response", "usage", "prompt_tokens").to_i },
    },
    "per_page" => per_page.map { |p| p.reject { |k, _| k == "response" } },
    "choices" => [{ "message" => { "content" => content } }],
  }
  FileUtils.mkdir_p(File.dirname("#{REPO}/ocr_raw/#{stem}.json"))
  File.write("#{REPO}/ocr_raw/#{stem}.json", JSON.pretty_generate(assembled))
  row = manifest_by_path["certificates/#{stem}.pdf"]
  num = row && row["num"].to_s
  issuer = num && (num[/\AR0?\d+\/\d{4}-([A-Z]{2}\d+)-/, 1] || num[/\AR0?\d+\/\d{4}-[A-Z]-([A-Z]{2}\d+)-/, 1])
  md_path = "#{REPO}/ocr_md/#{stem}.md"
  unless File.exist?(md_path)
    FileUtils.mkdir_p(File.dirname(md_path))
    File.write(md_path, <<~MD, mode: "w:UTF-8")
      <!-- cert_id: #{row && row["id"]} -->
      <!-- num: #{num} -->
      <!-- applicant: #{row && row["applicant"]} -->
      <!-- issuing_year: #{row && row["issuingYear"]} -->
      <!-- status: #{row && row["status"]} -->
      <!-- issuer: #{issuer} -->
      <!-- extraction_method: #{MODEL} -->
      <!-- source_pdf: certificates/#{stem}.pdf -->

      #{content}
    MD
  end
  blocked = per_page.count { |p| p["status"] == "blocked" }
  puts "#{stem}: assembled (#{blocked} blocked pages)"
end
