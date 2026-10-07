#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage-2 structured extraction: md -> layered record. Uses the frozen
# pipeline's SYSTEM_PROMPT verbatim (read from oiml_cs/extraction/glm_extractor.py
# at runtime so it cannot drift), calls glm-5.3-flash once per document, saves
# the verbatim API response under extract_raw/ (the permanent source tier), and
# derives the yaml record into pipeline-work/yaml/. Existing yaml files are
# never overwritten; a raw without a yaml is derived without calling the model.

require "net/http"
require "json"
require "yaml"
require "fileutils"
require "optparse"
require "base64"
require "digest"

REPO = File.expand_path("..", __dir__)
ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
MAX_TOKENS = 30_000
MAX_ATTEMPTS = 5
SECTIONS = %w[certificate issuing_authority applicants manufacturers certified_type
              characteristics recommendation test_reports revision_history
              model_family components footnotes matrix_tables]

SOURCE_FILE = "#{REPO}/oiml_cs/extraction/glm_extractor.py"
system_prompt = File.read(SOURCE_FILE)[/SYSTEM_PROMPT = """\\(.*?)"""/m, 1]
raise "could not read SYSTEM_PROMPT from #{SOURCE_FILE}" if system_prompt.to_s.empty?
system_prompt = system_prompt.gsub('\\\\', '\\')

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

def parse_model_json(text)
  s = text.to_s.strip
  s = s.sub(/\A```(?:json)?\s*\n/m, "").sub(/\n```\s*\z/m, "")
  begin
    JSON.parse(s)
  rescue JSON::ParserError
    # second chance: repair the model's common breakages — trailing commas
    # before a closing brace or bracket
    repaired = s.gsub(/,\s*([\]}])/, '\1')
    begin
      JSON.parse(repaired)
    rescue JSON::ParserError
      m = s.match(/\{.*\}/m)
      m ? JSON.parse(m[0]) : nil
    rescue JSON::ParserError
      nil
    end
  end
end

def md_header_and_body(path)
  raw = File.binread(path).force_encoding("UTF-8").scrub
  header = {}
  block = raw[/\A(?:<!--.*?-->\s*\n?)+/m].to_s
  block.scan(/<!--\s*(\w+):\s*(.*?)\s*-->/m) { |k, v| header[k] = v }
  body = raw.sub(/\A(?:<!--.*?-->\s*\n?)+/, "").strip
  [header, body]
end

def build_yaml(header, parsed)
  num = header["num"].to_s
  ordered = { "_meta" => {
    "cert_id" => header["cert_id"]&.to_i,
    "num" => num,
    "applicant" => header["applicant"],
    "issuing_year" => header["issuing_year"],
    "status" => header["status"],
    "issuer" => header["issuer"],
    "recommendation" => num[/\AR0?(\d+)\//] ? "R#{$1}" : nil,
    "edition_year" => num[/\AR0?\d+\/(\d{4})-/, 1]&.to_i,
    "extraction_method" => "glm-extract",
    "source_pdf" => header["source_pdf"],
  } }
  SECTIONS.each { |k| ordered[k] = parsed[k] if parsed.key?(k) }
  (parsed.keys - SECTIONS - %w[_meta]).each { |k| ordered[k] = parsed[k] }
  ordered.to_yaml(line_width: 100).sub(/\A---\n/, "")
end

# Raw responses come in two shapes: v4 chat/completions (until 2026-10-06)
# and Anthropic messages (after). Both must parse so old raws keep deriving.
def content_of(parsed_response)
  v4 = parsed_response.dig("choices", 0, "message", "content")
  return v4 if v4.is_a?(String) && !v4.empty?
  blocks = parsed_response["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

def call_extract(key, system_prompt, body)
  user_prompt = <<~PROMPT
    ## Certificate markdown
    ```markdown
    #{body}
    ```

    Return one JSON object conforming to the layered schema. No prose, no markdown fences around the JSON.
  PROMPT
  payload = {
    "model" => MODEL,
    "max_tokens" => MAX_TOKENS,
    "system" => system_prompt,
    "messages" => [{ "role" => "user", "content" => user_prompt }],
  }.to_json
  last_err = nil
  MAX_ATTEMPTS.times do |attempt|
    begin
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 600
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      req["x-api-key"] = key
      req["anthropic-version"] = "2023-06-01"
      req["Content-Type"] = "application/json"
      req.body = payload
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

mds = Dir.glob("#{REPO}/ocr_md/R*/**/*.md").sort.reject { |f| f =~ /backup/ }
mds.select! { |f| f =~ %r{/#{Regexp.escape(options[:family])}/} } if options[:family]

targets = []
have_yaml = 0
mds.each do |md|
  rel = md.delete_prefix("#{REPO}/ocr_md/").delete_suffix(".md")
  yaml_path = "#{REPO}/pipeline-work/yaml/#{rel}.yaml"
  if File.exist?(yaml_path)
    have_yaml += 1
    next
  end
  targets << [md, rel, yaml_path]
end
targets = targets.first(options[:limit]) if options[:limit]
warn "mds: #{mds.size}; already have yaml: #{have_yaml}; to extract: #{targets.size}"
exit 0 if targets.empty? || options[:dry_run]

FileUtils.mkdir_p("#{REPO}/extract_raw")
key = api_key
raise "no API key" if key.to_s.empty?

queue = Queue.new
targets.each { |t| queue << t }
failures = []
mutex = Mutex.new
workers = Array.new(options[:workers]) do
  Thread.new do
    loop do
      md, rel, yaml_path = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      t0 = Time.now
      begin
        raw_path = "#{REPO}/extract_raw/#{rel}.json"
        header, body = md_header_and_body(md)
        if File.exist?(raw_path)
          response = JSON.parse(File.read(raw_path))
        else
          response = call_extract(key, system_prompt, body)
          if response["error"] || content_of(response).to_s.empty?
            raise "API error for #{rel}: #{response.to_s[0, 250]}"
          end
          FileUtils.mkdir_p(File.dirname(raw_path))
          File.write(raw_path, JSON.pretty_generate(response))
        end
        parsed = parse_model_json(content_of(response))
        raise "unparseable JSON from model for #{rel}" if parsed.nil? || !parsed.is_a?(Hash)
        # Annex documents legitimately carry no type/characteristics sections;
        # only the certificate block is universal.
        missing = %w[certificate] - parsed.keys
        raise "missing required sections #{missing.inspect} for #{rel}" unless missing.empty?
        FileUtils.mkdir_p(File.dirname(yaml_path))
        File.write(yaml_path, build_yaml(header, parsed), mode: "w:UTF-8")
        mutex.synchronize do
          warn format("%s [%05d/%05d] %s (%.1fs)", Time.now.strftime("%H:%M:%S"), targets.size - queue.size, targets.size, rel, Time.now - t0)
        end
      rescue => e
        mutex.synchronize do
          failures << [rel, e.message]
          warn "FAIL #{rel}: #{e.message[0, 250]}"
        end
      end
    end
  end
end
workers.each(&:join)
warn format("done: %d extracted, %d failed", targets.size - failures.size, failures.size)
FileUtils.mkdir_p("#{REPO}/extract_raw")
File.open("#{REPO}/extract_raw/_failures.log", "a") { |f| failures.each { |rel, m| f.puts "#{Time.now}\t#{rel}\t#{m.gsub("\n", ' ')}" } } unless failures.empty?
