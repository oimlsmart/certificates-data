#!/usr/bin/env ruby
# frozen_string_literal: true

# Split extraction: for documents whose single-shot record JSON the model
# broke (dense matrices, 12k-34k char emissions) or whose single call kept
# losing the rate-limit lottery, split the markdown into chunks at structural
# boundaries, extract each chunk with the frozen system prompt, deep-merge the
# fragment records into one, and assemble a raw plus the derived yaml. Broken
# originals are kept as .broken; per-chunk raws as .partK. Never deletes.

require "net/http"
require "json"
require "yaml"
require "fileutils"
require "optparse"

REPO = File.expand_path("..", __dir__)
ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
MAX_TOKENS = 60_000
MAX_ATTEMPTS = 5
CHUNK_TARGET = 8_000
SECTIONS = %w[certificate issuing_authority applicants manufacturers certified_type
              characteristics recommendation test_reports revision_history
              model_family components footnotes matrix_tables]

SOURCE_FILE = "#{REPO}/oiml_cs/extraction/glm_extractor.py"
SYSTEM_PROMPT = File.read(SOURCE_FILE)[/SYSTEM_PROMPT = """\\(.*?)"""/m, 1].to_s.gsub("\\\\", "\\")
raise "could not read SYSTEM_PROMPT" if SYSTEM_PROMPT.empty?

options = { workers: 4, limit: nil, dry_run: false }
OptionParser.new { |o|
  o.on("--workers N", Integer) { |v| options[:workers] = v }
  o.on("--limit N", Integer) { |v| options[:limit] = v }
  o.on("--dry-run") { options[:dry_run] = true }
}.parse!

def api_key
  ENV["Z_AI_API_KEY"] || File.read(File.expand_path("~/.zai-api-key")).strip
end

def content_of(r)
  v4 = r.dig("choices", 0, "message", "content")
  return v4 if v4.is_a?(String) && !v4.empty?
  blocks = r["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

def parse_model_json(text)
  s = text.to_s.strip
  s = s.sub(/\A```(?:json)?\s*\n/m, "").sub(/\n```\s*\z/m, "")
  begin
    JSON.parse(s)
  rescue JSON::ParserError
    begin
      JSON.parse(s.gsub(/,\s*([\]}])/, '\1'))
    rescue JSON::ParserError
      m = s.match(/\{.*\}/m)
      begin
        m ? JSON.parse(m[0]) : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end

def deep_merge(a, b)
  if a.is_a?(Hash) && b.is_a?(Hash)
    a.merge(b) { |_k, x, y| deep_merge(x, y) }
  elsif a.is_a?(Array) && b.is_a?(Array)
    seen = a.map { |e| JSON.generate(e) }
    a + b.reject { |e| seen.include?(JSON.generate(e)) }
  elsif b.nil?
    a
  else
    b
  end
end

def chunk_markdown(body)
  lines = body.lines
  chunks = []
  current = +""
  current_bytes = 0
  lines.each do |line|
    boundary = line =~ /\A(\#{1,6} |<table|## Categories|---)/
    if current_bytes + line.bytesize > CHUNK_TARGET && current_bytes > CHUNK_TARGET / 2
      if boundary || current_bytes > CHUNK_TARGET * 2
        chunks << current
        current = +""
        current_bytes = 0
      end
    end
    current << line
    current_bytes += line.bytesize
  end
  chunks << current unless current.strip.empty?
  chunks
end

def call_chunk(key, part, total, chunk)
  payload = {
    model: MODEL, max_tokens: MAX_TOKENS, system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: <<~PROMPT
      ## Certificate markdown (part #{part} of #{total} — a fragment of one certificate)
      ```markdown
      #{chunk}
      ```

      Return one JSON object conforming to the layered schema for the content present in THIS fragment only. Omit sections that are not present in this fragment. Return only the JSON.
    PROMPT
    }],
  }.to_json
  last_err = nil
  MAX_ATTEMPTS.times do |attempt|
    begin
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 600
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      req["x-api-key"] = api_key
      req["anthropic-version"] = "2023-06-01"
      req["Content-Type"] = "application/json"
      req.body = payload
      res = http.request(req)
      parsed = JSON.parse(res.body)
      retryable = res.code.to_i == 429 || parsed.dig("error", "code").to_s == "1302"
      return parsed if res.code.to_i < 500 && !retryable
      last_err = "HTTP #{res.code}: #{res.body[0, 160]}"
      if retryable
        sleep(20 * (attempt + 1))
        next
      end
    rescue JSON::ParserError
      return { "error" => "non-JSON response" }
    rescue => e
      last_err = e.message
    end
    sleep(2**attempt)
  end
  { "error" => last_err || "exhausted retries" }
end

def md_header(path)
  raw = File.binread(path).force_encoding("UTF-8").scrub
  header = {}
  raw[/\A(?:<!--.*?-->\s*\n?)+/m].to_s.scan(/<!--\s*(\w+):\s*(.*?)\s*-->/m) { |k, v| header[k] = v }
  header
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

# targets: every md without a yaml
targets = Dir.glob("#{REPO}/ocr_md/R*/**/*.md").sort.reject { |f| f =~ /backup/ }.map { |md|
  md.sub(%r{\A#{REPO}/ocr_md/}, "").sub(/\.md\z/, "")
}.reject { |rel| File.exist?("#{REPO}/pipeline-work/yaml/#{rel}.yaml") }
targets = targets.first(options[:limit]) if options[:limit]

warn "targets: #{targets.size}"
exit 0 if targets.empty? || options[:dry_run]

key = api_key
queue = Queue.new
targets.each { |t| queue << t }
failures = []
mutex = Mutex.new
workers = Array.new(options[:workers]) do
  Thread.new do
    loop do
      rel = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      t0 = Time.now
      begin
        md_path = "#{REPO}/ocr_md/#{rel}.md"
        body = File.binread(md_path).force_encoding("UTF-8").scrub.sub(/\A(?:<!--.*?-->\s*\n?)+/, "").strip
        raw_path = "#{REPO}/extract_raw/#{rel}.json"
        FileUtils.mkdir_p(File.dirname(raw_path))
        chunks = chunk_markdown(body)
        chunk_results = []
        chunks.each_with_index do |chunk, i|
          part_path = "#{raw_path}.part#{i + 1}"
          cached = File.exist?(part_path) ? (JSON.parse(File.read(part_path)) rescue nil) : nil
          cached = nil if cached && cached["stop_reason"] == "max_tokens" # truncated: re-call
          response = cached || call_chunk(key, i + 1, chunks.size, chunk)
          if response["error"] || content_of(response).to_s.empty?
            raise "part #{i + 1} of #{rel}: #{response.to_s[0, 200]}"
          end
          File.write(part_path, JSON.pretty_generate(response)) unless File.exist?(part_path)
          parsed = parse_model_json(content_of(response))
          raise "part #{i + 1} of #{rel}: unparseable JSON" if parsed.nil? || !parsed.is_a?(Hash)
          chunk_results << parsed
        end
        assembled = chunk_results.reduce({}) { |acc, frag| deep_merge(acc, frag) }
        raise "#{rel}: no certificate section assembled" unless assembled["certificate"]
        broken = File.exist?(raw_path)
        File.rename(raw_path, "#{raw_path}.broken#{Dir.glob("#{raw_path}.broken*").size + 1}") if broken
        assembled_raw = {
          "model" => "#{MODEL}-split",
          "created" => Time.now.to_i,
          "usage" => {
            "completion_tokens" => Dir.glob("#{raw_path}.part*").sum { |p| JSON.parse(File.read(p)).dig("usage", "output_tokens").to_i rescue 0 },
          },
          "chunks" => chunks.size,
          "assembled_from" => (1..chunks.size).map { |i| "#{File.basename(raw_path)}.part#{i}" },
          "choices" => [{ "message" => { "role" => "assistant", "content" => JSON.generate(assembled) } }],
        }
        File.write(raw_path, JSON.pretty_generate(assembled_raw))
        yaml_path = "#{REPO}/pipeline-work/yaml/#{rel}.yaml"
        FileUtils.mkdir_p(File.dirname(yaml_path))
        File.write(yaml_path, build_yaml(md_header(md_path), assembled), mode: "w:UTF-8")
        mutex.synchronize do
          warn format("%s OK %s (%d chunks, %.0fs)", Time.now.strftime("%H:%M:%S"), rel, chunks.size, Time.now - t0)
        end
      rescue => e
        mutex.synchronize do
          failures << rel
          warn "FAIL #{rel}: #{e.message[0, 200]}"
        end
      end
    end
  end
end
workers.each(&:join)
warn "done: #{targets.size - failures.size} ok, #{failures.size} failed"
