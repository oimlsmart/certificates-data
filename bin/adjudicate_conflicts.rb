#!/usr/bin/env ruby
# frozen_string_literal: true

# Reconciliation layer two: model adjudication of the conflicts layer one
# found. For each conflicting axis, the model sees the register's value, the
# document's value, and the document's own applicant/authority context, and
# returns a verdict: same-entity (spelling drift), different-entity (real
# disagreement), document-noise (extraction artifact), or unverifiable — plus
# the best value for the fused record. Every response is committed verbatim
# under reconcile_raw/ (the permanent source; never re-run without need).

require "net/http"
require "json"
require "fileutils"

REPO = File.expand_path("..", __dir__)
ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
MAX_TOKENS = 4_000

def api_key
  ENV["Z_AI_API_KEY"] || File.read(File.expand_path("~/.zai-api-key")).strip
end

def call(key, prompt)
  payload = { model: MODEL, max_tokens: MAX_TOKENS,
              messages: [{ role: "user", content: prompt }] }.to_json
  5.times do |attempt|
    begin
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = 30
      http.read_timeout = 300
      req = Net::HTTP::Post.new(ENDPOINT.request_uri)
      req["x-api-key"] = api_key
      req["anthropic-version"] = "2023-06-01"
      req["Content-Type"] = "application/json"
      req.body = payload
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

def text_of(r)
  Array(r["content"]).to_a.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
end

def parse_verdict(t)
  s = t.to_s.sub(/\A```(?:json)?\s*\n/m, "").sub(/\n```\s*\z/m, "").strip
  JSON.parse(s)
rescue JSON::ParserError
  m = s.match(/\{.*\}/m)
  m ? JSON.parse(m[0]) : nil
rescue JSON::ParserError
  nil
end

def context_for(rel, axis)
  md = "#{REPO}/ocr_md/#{rel}.md"
  return "" unless File.exist?(md)
  body = File.binread(md).force_encoding("UTF-8").scrub
  if axis == "applicant"
    i = body =~ /\bapplic/i
    i ? body[[i - 100, 0].max, 700] : body[0, 500]
  else
    body[0, 500]
  end
end

rows = File.readlines("#{REPO}/datasets/reconciliation.jsonl").map { |l| JSON.parse(l) }
targets = rows.select { |r| r["overall"] == "conflict" }
warn "conflict records to adjudicate: #{targets.size}"
key = api_key
FileUtils.mkdir_p("#{REPO}/reconcile_raw")

done = 0
out = File.open("#{REPO}/datasets/adjudications.jsonl", "w:UTF-8")
targets.each do |row|
  raw_path = "#{REPO}/reconcile_raw/#{row['cert_id']}.json"
  if File.exist?(raw_path)
    response = JSON.parse(File.read(raw_path))
  else
    cmp = row["comparisons"].select { |c| c["verdict"] == "conflict" }
    lines = cmp.map { |c| "axis #{c['axis']}:\n  register: #{c['register'].inspect}\n  document: #{c['document'].inspect}" }.join("\n")
    ctx = context_for(row["record"], cmp.first["axis"]).gsub(/\s+/, " ")[0, 600]
    prompt = <<~PROMPT
      An OIML certificate has two data surfaces. The register (the OIML-CS database row) says one thing; the certificate document itself says another. For each conflicting axis, decide the relationship and pick the best value for a fused record.

      Certificate: #{row['num']} (register id #{row['cert_id']})
      Document context (from the certificate's own text): "#{ctx}"

      Conflicts:
      #{lines}

      Return one JSON object: {"axes": [{"axis": "<axis>", "verdict": "same-entity" | "different-entity" | "document-noise" | "unverifiable", "best_value": "<the value the fused record should carry>", "why": "<one short sentence>"}]}
      Rules: spelling drift, legal-suffix drift, accent differences = same-entity. Extraction artifacts (address fragments glued into a name, obvious OCR noise) = document-noise with best_value from the register. Genuinely different company or person names = different-entity (best_value = the document's, since the certificate is the legal instrument). Number/year format differences that clearly denote the same certificate = same-entity with the register's canonical form.
    PROMPT
    response = call(key, prompt)
    if response["error"] || text_of(response).to_s.empty?
      warn "FAIL #{row['cert_id']}: #{response.to_s[0, 120]}"
      next
    end
    File.write(raw_path, JSON.pretty_generate(response))
  end
  verdict = parse_verdict(text_of(response))
  if verdict.nil?
    warn "UNPARSEABLE #{row['cert_id']}"
    next
  end
  out.puts(JSON.generate({ "cert_id" => row["cert_id"], "num" => row["num"],
                           "axes" => verdict["axes"] }))
  done += 1
  warn format("%s %05d %s", Time.now.strftime("%H:%M:%S"), done, row["num"]) if (done % 25).zero?
end
out.close
warn "adjudicated: #{done} of #{targets.size}"
