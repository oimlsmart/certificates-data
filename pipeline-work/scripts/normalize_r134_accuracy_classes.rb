#!/usr/bin/env ruby
# Normalize accuracy_classes in R134 certs: split "X or Y" → [X, Y], stringify, drop non-class tokens.
require "yaml"
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
YAML_ROOT = ROOT + "yaml/R134/2006"

def normalize_classes(arr)
  out = []
  arr.each do |c|
    if c.is_a?(Integer) || c.is_a?(Float)
      out << c.to_s
    elsif c.is_a?(String)
      if c =~ /^not\s+supported$/i || c =~ /^n\/a$/i || c =~ /^none$/i || c.empty?
        next
      end
      if c =~ /or\s+higher$/i
        m = c.match(/^(.+?)\s+or\s+higher$/i)
        out << (m ? m[1].strip : c)
      elsif c =~ /and\s+higher$/i
        m = c.match(/^(.+?)\s+and\s+higher$/i)
        out << (m ? m[1].strip : c)
      elsif c =~ /\bor\b/i
        c.split(/\s+or\s+/i).each { |p| out << p.strip unless p.strip.empty? }
      else
        out << c.strip
      end
    end
  end
  out.uniq
end

fixed = 0
Pathname.glob(YAML_ROOT + "*.yaml").sort.each do |yp|
  data = YAML.load_file(yp)
  next unless data.is_a?(Hash)
  rec = data["recommendation"]
  next unless rec.is_a?(Hash)
  ac = rec["accuracy_classes"]
  next if ac.nil? || ac.empty?
  new_ac = normalize_classes(ac)
  if new_ac != ac
    rec["accuracy_classes"] = new_ac
    yp.write(YAML.dump(data))
    fixed += 1
    puts "#{yp.basename}: #{ac.inspect} → #{new_ac.inspect}"
  end
end
puts "Fixed accuracy_classes in #{fixed} R134 certs"
