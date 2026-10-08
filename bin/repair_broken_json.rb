#!/usr/bin/env ruby
# frozen_string_literal: true

# Repair pass for raws whose model JSON cannot parse (unescaped quotes around
# inch marks and quoted designations are the dominant cause). Each broken raw
# is set aside as .broken (never deleted), the model is asked once to return
# the same object as valid JSON, and the repaired response becomes the raw.
# Repairs only run where the primary parse and the trailing-comma repair both
# fail. Deterministic inventory; idempotent.

require "net/http"
require "json"
require "fileutils"

REPO = File.expand_path("..", __dir__)
ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
MAX_TOKENS = 30_000

def api_key
  ENV["Z_AI_API_KEY"] || File.read(File.expand_path("~/.zai-api-key")).strip
end

def parse_candidate(text)
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

def content_of(r)
  v4 = r.dig("choices", 0, "message", "content")
  return v4 if v4.is_a?(String) && !v4.empty?
  blocks = r["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

def call_repair(key, broken_text)
  body = {
    model: MODEL, max_tokens: MAX_TOKENS,
    messages: [{ role: "user", content: <<~PROMPT
      The following text is a JSON object extracted from an OIML certificate
      record, but it is not valid JSON — internal double quotes (inch marks,
      quoted designations) were not escaped. Return the SAME object as one
      valid JSON object with all internal quotes properly escaped, nothing
      added or removed, no markdown fences.

      ```
      #{broken_text[0, 60_000]}
      ```
    PROMPT
    }],
  }.to_json
  5.times do |attempt|
    begin
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 600
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      req["x-api-key"] = api_key
      req["anthropic-version"] = "2023-06-01"
      req["Content-Type"] = "application/json"
      req.body = body
      res = http.request(req)
      parsed = JSON.parse(res.body)
      retryable = res.code.to_i == 429 || parsed.dig("error", "code").to_s == "1302"
      return parsed if res.code.to_i < 500 && !retryable
    rescue JSON::ParserError
      return { "error" => "non-JSON response" }
    rescue => e
      return { "error" => e.message } if attempt == 4
    end
    sleep(20 * (attempt + 1))
  end
  { "error" => "exhausted retries" }
end

broken = []
Dir.glob("#{REPO}/extract_raw/R*/**/*.json").sort.each do |raw|
  next if File.exist?("#{raw}.broken")
  begin
    r = JSON.parse(File.read(raw))
  rescue JSON::ParserError
    next
  end
  text = content_of(r).to_s
  next if text.empty?
  broken << [raw, text] if parse_candidate(text).nil?
end

puts "broken raws to repair: #{broken.size}"
key = api_key
fixed = 0
still = []
broken.each do |raw, text|
  response = call_repair(key, text)
  repaired_text = content_of(response)
  if response["error"] || repaired_text.to_s.empty? || parse_candidate(repaired_text).nil?
    still << raw
    puts "  STILL BROKEN: #{raw.delete_prefix("#{REPO}/extract_raw/")}"
    next
  end
  File.rename(raw, "#{raw}.broken")
  File.write(raw, JSON.pretty_generate(response))
  fixed += 1
  puts "  repaired: #{File.basename(raw)}"
end
puts "repaired: #{fixed}; still broken: #{still.size}"
