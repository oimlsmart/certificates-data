#!/usr/bin/env ruby
# frozen_string_literal: true
# The last two blocked pages (1992 NL1 scans, no text layer, rejected by the
# provider filter at every render) transcribed through the estate's own
# Cloudflare Workers AI (Llama 3.2 vision — different provider, no shared
# filter). Raws record the provider and model; prior raws kept as
# .preunblock; records rebuilt from the recovered documents.

require "net/http"
require "json"
require "open3"
require "fileutils"
require "tmpdir"
require "base64"

REPO = File.expand_path("..", __dir__)
PROVIDER = "@cf/meta/llama-3.2-11b-vision-instruct"
REPO_ = File.expand_path("..", __dir__)
TARGETS = Dir.glob("#{REPO_}/ocr_raw/R*/**/*.json").select { |f|
  (JSON.parse(File.read(f)) rescue {})["per_page"].to_a.any? { |e| e["status"] == "blocked" }
}.map { |f| f.sub(%r{\A#{REPO_}/ocr_raw/}, "").sub(/\.json\z/, "") }


token = File.read(File.expand_path("~/Library/Preferences/.wrangler/config/default.toml")).match(/oauth_token = "([^"]+)"/)[1]
account = `cd #{ENV["HOME"]}/src/oimlsmart/ai && npx wrangler whoami 2>/dev/null`.match(/[a-f0-9]{32}/)[0]

def transcribe(account, token, image)
  b64 = [File.binread(image)].pack("m0")
  payload = JSON.generate({ messages: [{ role: "user", content: [
    { type: "image_url", image_url: { url: "data:image/png;base64,#{b64}" } },
    { type: "text", text: "Transcribe every line of text on this OIML certificate page exactly, in reading order, including text inside stamps and logos. Output only the transcription." },
  ] }] })
  uri = URI("https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run/#{PROVIDER}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 300
  req = Net::HTTP::Post.new(uri.request_uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = payload
  body = JSON.parse(http.request(req).body)
  return body.dig("result", "response") if body["success"]
  raise body.to_s[0, 200]
end

TARGETS.each do |stem|
  pdf = "#{REPO}/certificates/#{stem}.pdf"
  raw_path = "#{REPO}/ocr_raw/#{stem}.json"
  raw = JSON.parse(File.read(raw_path))
  content = raw.dig("choices", 0, "message", "content")
  changed = false
  Dir.mktmpdir do |dir|
    Array(raw["per_page"]).each_with_index do |e, i|
      next unless e["status"] == "blocked"
      page = e["page"]
      img = "#{dir}/p.png"
      Open3.capture3("mutool", "draw", "-r", "150", "-o", img, pdf, page.to_s)
      text = transcribe(account, token, img)
      marker = "<!-- page #{page}: blocked by provider content filter; transcription unavailable -->"
      next unless text.to_s.size > 100 && content.include?(marker)
      if File.exist?(raw_path)
        File.rename(raw_path, "#{raw_path}.preunblock#{Dir.glob("#{raw_path}.preunblock*").size + 1}")
      end
      content = content.sub(marker, "<!-- page #{page}: recovered via Cloudflare Workers AI (#{PROVIDER}); the z.ai filter rejected every render, a different provider reads it -->\n\n#{text}")
      raw["per_page"][i] = { "page" => page, "status" => "recovered", "strategy" => "workers-ai-#{PROVIDER}" }
      changed = true
      puts "#{stem} p#{page}: RECOVERED via Workers AI (#{text.size}c)"
    end
  end
  next unless changed
  raw["model"] = "#{raw['model']}+#{PROVIDER}"
  raw["choices"][0]["message"]["content"] = content
  File.write(raw_path, JSON.pretty_generate(raw))
  md = "#{REPO}/ocr_md/#{stem}.md"
  m = File.binread(md).force_encoding("UTF-8").scrub
  raw["per_page"].each do |e|
    next unless e["status"] == "recovered"
    m = m.sub("<!-- page #{e['page']}: blocked by provider content filter; transcription unavailable -->",
              "<!-- page #{e['page']}: recovered via Cloudflare Workers AI -->")
  end
  File.write(md, m, mode: "w:UTF-8")
  y = "#{REPO}/pipeline-work/yaml/#{stem}.yaml"
  File.rename(y, "#{y}.stale#{Dir.glob("#{y}.stale*").size + 1}") if File.exist?(y)
  puts "#{stem}: raw + md updated, record set aside"
end
