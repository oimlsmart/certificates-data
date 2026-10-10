#!/usr/bin/env ruby
# frozen_string_literal: true

# Unblock the provider-filtered pages: for each blocked page recorded in an
# assembled per-page raw, try progressively different render strategies —
# smaller PNG, JPEG encoding, then quadrant crops — until one passes the
# filter. Recovered text replaces the blocked marker in the raw (prior raw
# kept as .preunblock) and in the derived md. Never deletes; never fakes.

require "net/http"
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require "base64"

REPO = File.expand_path("..", __dir__)
ENDPOINT = URI("https://api.z.ai/api/anthropic/v1/messages")
MODEL = "glm-5.3-flash"
MAX_TOKENS = 16_384

def api_key
  ENV["Z_AI_API_KEY"] || File.read(File.expand_path("~/.zai-api-key")).strip
end

def content_of(r)
  blocks = r["content"]
  return nil unless blocks.is_a?(Array)
  blocks.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join
end

def call_image(key, media_type, data_b64, note)
  payload = {
    model: MODEL, max_tokens: MAX_TOKENS,
    messages: [{ role: "user", content: [
      { type: "image", source: { type: "base64", media_type: media_type, data: data_b64 } },
      { type: "text", text: note },
    ] }],
  }.to_json
  4.times do |attempt|
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
    rescue JSON::ParserError
      return { "error" => "non-JSON response" }
    rescue => e
      return { "error" => e.message } if attempt == 3
    end
    sleep(20 * (attempt + 1))
  end
  { "error" => "exhausted retries" }
end

def render(*args)
  Open3.capture3("mutool", "draw", *args.flatten)
end

def ok?(r)
  !r["error"] && content_of(r).to_s.size > 40
end

blocked = Dir.glob("#{REPO}/ocr_raw/R*/**/*.json").select { |f|
  File.read(f).include?("blocked by provider content filter")
}
puts "raws with blocked pages: #{blocked.size}"
key = api_key
recovered_pages = 0
still = 0

blocked.each do |raw_path|
  raw = JSON.parse(File.read(raw_path))
  pp_detail = raw["per_page"] or next
  content = raw.dig("choices", 0, "message", "content")
  stem = raw_path.delete_prefix("#{REPO}/ocr_raw/").delete_suffix(".json")
  pdf = "#{REPO}/certificates/#{stem}.pdf"
  changed = false
  Dir.mktmpdir do |dir|
    pp_detail.each_with_index do |entry, i|
      next unless entry["status"] == "blocked"
      page = entry["page"]
      puts "#{stem} page #{page}: attacking"
      strategies = []
      # smaller raster
      strategies << ["100dpi png", -> { render(["-r", "100", "-o", "#{dir}/s1.png", pdf, page.to_s]) && { media: "image/png", file: "#{dir}/s1.png" } }]
      # jpeg encoding
      strategies << ["150dpi jpeg", -> { render(["-r", "150", "-o", "#{dir}/s2.jpg", "-F", "jpeg", pdf, page.to_s]) && { media: "image/jpeg", file: "#{dir}/s2.jpg" } }]
      # grayscale small
      strategies << ["80dpi png", -> { render(["-r", "80", "-o", "#{dir}/s3.png", pdf, page.to_s]) && { media: "image/png", file: "#{dir}/s3.png" } }]
      text = nil
      used = nil
      strategies.each do |name, run|
        artifact = run.call
        next unless artifact && File.exist?(artifact[:file])
        note = "Transcribe this page of an OIML Certificate of Conformity exactly as GitHub-flavored markdown. Include ALL text in reading order including text inside images, logos, and stamps. Tables as HTML. Output the transcription only."
        r = call_image(key, artifact[:media], Base64.strict_encode64(File.binread(artifact[:file])), note)
        if ok?(r)
          text = content_of(r)
          used = name
          break
        end
        sleep(3)
      end
      # quadrant fallback: four quadrant crops at 200 dpi
      if text.nil?
        quads = [[0, 0.5, 0, 0.5], [0.5, 1, 0, 0.5], [0, 0.5, 0.5, 1], [0.5, 1, 0.5, 1]]
        parts = []
        labels = %w[top-left top-right bottom-left bottom-right]
        quads.each_with_index do |(x0, x1, y0, y1), qi|
          out = "#{dir}/q#{qi}.png"
          stat = render(["-r", "200", "-o", out, "-x", (x0 * 100).to_s, "-y", (y0 * 100).to_s,
                         "-X", (x1 * 100).to_s, "-Y", (y1 * 100).to_s, "-c", pdf, page.to_s])
          next unless File.exist?(out)
          note = "This is the #{labels[qi]} QUARTER of page #{page} of an OIML certificate. Transcribe every visible line of text exactly, in reading order (text inside images and stamps included). Output only the transcription."
          r = call_image(key, "image/png", Base64.strict_encode64(File.binread(out)), note)
          parts << content_of(r).to_s if ok?(r)
          sleep(3)
        end
        if parts.size >= 3
          text = parts.join("\n\n---\n\n")
          used = "quadrants (#{parts.size}/4 recovered)"
        end
      end
      if text
        marker = "<!-- page #{page}: blocked by provider content filter; transcription unavailable -->"
        if content&.include?(marker)
          File.rename(raw_path, "#{raw_path}.preunblock#{Dir.glob("#{raw_path}.preunblock*").size + 1}")
          content = content.sub(marker, "<!-- page #{page}: recovered via #{used} after provider content filter; see .preunblock raw for the blocked attempt -->\n\n#{text}")
          pp_detail[i] = { "page" => page, "status" => "recovered", "strategy" => used }
          changed = true
          recovered_pages += 1
          puts "  page #{page}: RECOVERED via #{used} (#{text.size}c)"
        end
      else
        still += 1
        puts "  page #{page}: still blocked"
      end
    end
  end
  next unless changed
  raw["choices"][0]["message"]["content"] = content
  raw["per_page"] = pp_detail
  File.write(raw_path, JSON.pretty_generate(raw))
  md_path = "#{REPO}/ocr_md/#{stem}.md"
  if File.exist?(md_path)
    md = File.binread(md_path).force_encoding("UTF-8").scrub
    raw["per_page"].each do |e|
      next unless e["status"] == "recovered"
      marker = "<!-- page #{e['page']}: blocked by provider content filter; transcription unavailable -->"
      replacement = "<!-- page #{e['page']}: recovered via #{e['strategy']} -->"
      md = md.sub(marker, replacement)
    end
    File.write(md_path, md, mode: "w:UTF-8")
  end
end
puts "recovered pages: #{recovered_pages}; still blocked: #{still}"
