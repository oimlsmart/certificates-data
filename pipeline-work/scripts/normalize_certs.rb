#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative "../lib/oiml_cert/normalizer"
require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))

# Force-rewrite all certs through the normalizer
count_total = 0
count_changed = 0

Dir.glob(ROOT.join("yaml", "R*", "**", "*.yaml")).sort.each do |path|
  count_total += 1
  raw = File.read(path)
  cert = YAML.safe_load(raw, permitted_classes: [Date, Time, Symbol])
  next unless cert.is_a?(Hash)
  normalized = OimlCert::Normalizer.normalize_cert(cert)
  next if normalized == cert
  count_changed += 1
  File.write(path, YAML.dump(normalized, line_width: 120))
end

$stderr.puts "Normalized #{count_changed}/#{count_total} certs"
