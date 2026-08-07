# frozen_string_literal: true

require "yaml"
require "pathname"

module OimlCs
  # Normalizer: coerces every characteristic value to its declared type.
  #
  # Data-driven: reads type specs from schema/_modules/*.yaml and
  # schema/R<NN>.yaml. For values that cannot be coerced (formulas,
  # descriptive text), sets value to null and preserves the original
  # under _raw so nothing is lost.
  #
  # Architecture:
  #   normalizer = Normalizer.new(schema_dir: Pathname.new("schema"))
  #   normalizer.normalize_all!(yaml_root: Pathname.new("yaml"))
  #
  # The result is a fully normalized model: every characteristic value
  # conforms to its declared type or is null.

  class Normalizer
    attr_reader :stats

    def initialize(schema_dir:)
      @schema_dir = schema_dir
      @modules_dir = schema_dir + "_modules"
      @modules = load_modules
      @stats = Hash.new { |h, k| h[k] = { total: 0, changed: 0, nulled: 0, samples: [] } }
    end

    # ── Public API ────────────────────────────────────────────────────

    def normalize_all!(yaml_root:)
      Pathname.glob(yaml_root + "R*" + "*" + "*.yaml").sort.each do |yp|
        normalize_file!(yp)
      end
      self
    end

    def report
      puts "=== NORMALIZATION REPORT ==="
      puts format("%-6s %8s %8s %8s", "R", "certs", "changed", "nulled")
      total_c = total_n = 0
      @stats.keys.sort_by { |r| r[1..].to_i }.each do |r|
        v = @stats[r]
        total_c += v[:changed]
        total_n += v[:nulled]
        puts format("  %-6s %8d %8d %8d", r, v[:total], v[:changed], v[:nulled])
      end
      puts format("  %-6s %8d %8d", "TOTAL", total_c, total_n)
    end

    def normalize_file!(yaml_path)
      r_str = yaml_path.parent.parent.basename.to_s
      @stats[r_str][:total] += 1

      data = read_yaml(yaml_path)
      return unless data.is_a?(Hash)

      changed = false
      chars = data.dig("characteristics", "type_level") || {}

      chars.each do |label, vobj|
        next unless vobj.is_a?(Hash)
        type = resolve_type(label, r_str)
        next unless type

        original = vobj["value"]
        result = normalize_value(type, vobj, label, r_str)

        if result == :changed
          changed = true
          @stats[r_str][:changed] += 1
        elsif result == :nulled
          changed = true
          @stats[r_str][:nulled] += 1
        end
      end

      write_yaml(yaml_path, data) if changed
    end

    # ── Type dispatch (data-driven) ──────────────────────────────────

    private

    def normalize_value(type, vobj, label, r_str)
      case type
      when "enum"       then normalize_enum(vobj, resolve_enum_values(label, r_str))
      when "enum_multi" then normalize_enum_multi(vobj, resolve_enum_values(label, r_str))
      when "numeric"    then normalize_numeric(vobj)
      when "int"        then normalize_int(vobj)
      when "range"      then normalize_range(vobj)
      when "compound"   then normalize_compound(vobj, resolve_structure(label, r_str))
      when "boolean"    then normalize_boolean(vobj)
      when "string"     then nil
      else nil
      end
    end

    # ── Enum normalizer ──────────────────────────────────────────────

    def normalize_enum(vobj, allowed)
      return nil unless allowed && allowed.any?
      val = vobj["value"]
      return nil if val.nil?

      vals = val.is_a?(Array) ? val : [val]
      result = vals.map { |v| match_enum(v, allowed) }

      if result.all? { |r| r } && result != vals
        vobj["value"] = result.size == 1 ? result.first : result
        :changed
      elsif result.any? { |r| !r }
        # Can't match — null it
        vobj["_raw"] = val
        vobj["value"] = nil
        :nulled
      end
    end

    def normalize_enum_multi(vobj, allowed)
      normalize_enum(vobj, allowed) # same logic
    end

    def match_enum(val, allowed)
      s = val.to_s.strip
      # Exact match
      return s if allowed.include?(s)
      # Case-insensitive match
      allowed.find { |a| a.downcase == s.downcase }
      # Fuzzy: strip hyphens/underscores/punctuation
      norm = s.downcase.gsub(/[-_.]/, " ").strip
      allowed.find { |a| a.downcase.gsub(/[-_.]/, " ").strip == norm }
    end

    # ── Numeric normalizer ───────────────────────────────────────────

    def normalize_numeric(vobj)
      val = unwrap(vobj["value"])
      return nil if val.nil?

      case val
      when Numeric
        vobj["value"] = val
        nil
      when String
        n = extract_number(val)
        if n
          vobj["value"] = n
          vobj["_raw"] = val unless val.match?(/^[\d.,\s]+$/)
          :changed
        else
          # Formula or descriptive text — null it
          vobj["_raw"] = val
          vobj["value"] = nil
          :nulled
        end
      when Hash
        # Range dict where number expected — extract min (for minimum_*) or max
        n = val.transform_keys(&:to_s)
        extracted = n["value"] || n["min"] || n["max"]
        if extracted.is_a?(Numeric)
          vobj["value"] = extracted
          vobj["_raw"] = val
          :changed
        else
          vobj["_raw"] = val
          vobj["value"] = nil
          :nulled
        end
      end
    end

    # ── Int normalizer ───────────────────────────────────────────────

    def normalize_int(vobj)
      result = normalize_numeric(vobj)
      return result unless result

      val = vobj["value"]
      if val.is_a?(Float)
        if val == val.to_i
          vobj["value"] = val.to_i
          :changed
        else
          vobj["_raw"] ||= val
          vobj["value"] = val.round
          :changed
        end
      end
      result
    end

    # ── Range normalizer ─────────────────────────────────────────────

    def normalize_range(vobj)
      val = unwrap(vobj["value"])
      return nil if val.nil?

      case val
      when Hash
        h = val.transform_keys(&:to_s)
        if h.key?("min") || h.key?("max")
          new_val = { "min" => h["min"], "max" => h["max"] }
          old_val = vobj["value"]
          vobj["value"] = new_val
          old_val == new_val ? nil : :changed
        else
          null_value(vobj, val)
        end
      when Numeric
        vobj["value"] = { "min" => val, "max" => val }
        :changed
      when String
        range = parse_range(val)
        if range
          vobj["value"] = { "min" => range[0], "max" => range[1] }
          vobj["_raw"] = val if val.match?(/[a-zA-Z;]/)
          :changed
        else
          null_value(vobj, val)
        end
      when Array
        # List of range strings — take the first parseable range
        if val.size == 1 && val[0].is_a?(Hash)
          h = val[0].transform_keys(&:to_s)
          vobj["value"] = { "min" => h["min"], "max" => h["max"] }
          :changed
        else
          # Try to extract range from first string element
          first_str = val.find { |v| v.is_a?(String) }
          if first_str
            range = parse_range(first_str)
            if range
              vobj["value"] = { "min" => range[0], "max" => range[1] }
              vobj["_raw"] = val
              :changed
            else
              null_value(vobj, val)
            end
          else
            null_value(vobj, val)
          end
        end
      end
    end

    # ── Compound normalizer ──────────────────────────────────────────

    def normalize_compound(vobj, structure)
      return nil unless structure
      val = vobj["value"]
      return nil if val.nil?

      if val.is_a?(Hash)
        # Already structured — verify keys match
        h = val.transform_keys(&:to_s)
        valid = structure.keys.all? { |k| h.key?(k.to_s) || !structure[k] }
        return nil # accept as-is
      end

      # Try to decompose string like "M1, E1, H3" or "M3/E2+E31"
      if val.is_a?(String) || (val.is_a?(Array) && val.all? { |v| v.is_a?(String) })
        s = val.is_a?(Array) ? val.join(",") : val
        decomposed = decompose_compound_string(s, structure)
        if decomposed
          vobj["value"] = decomposed
          vobj["_raw"] = val
          :changed
        else
          null_value(vobj, val)
        end
      end
    end

    def decompose_compound_string(s, structure)
      result = {}
      parts = s.split(/[,;\/\s]+/).reject(&:empty?)
      structure.each_key do |key|
        prefix = key.to_s[0].upcase # "mechanical" → "M"
        match = parts.find { |p| p.upcase.start_with?(prefix) && p.match?(/^#{prefix}\d/) }
        result[key.to_s] = match if match
        # Handle "E2+E3" → take first
        if match&.include?("+")
          result[key.to_s] = match.split("+").first
        end
      end
      result.empty? ? nil : result
    end

    # ── Boolean normalizer ───────────────────────────────────────────

    def normalize_boolean(vobj)
      val = vobj["value"]
      return nil if val.nil? || [true, false].include?(val)

      s = val.to_s.downcase
      case s
      when "yes", "true", "applicable", "1"
        vobj["value"] = true
        :changed
      when "no", "false", "not applicable", "not-applicable", "0"
        vobj["value"] = false
        :changed
      else
        null_value(vobj, val)
      end
    end

    # ── Helpers ──────────────────────────────────────────────────────

    def unwrap(val)
      # Unwrap nested value-objects and array-wrappers
      v = val
      v = v[0] if v.is_a?(Array) && v.size == 1
      if v.is_a?(Hash) && v.key?("value") && v.key?("unit_symbol")
        v = v["value"]
      end
      v
    end

    def null_value(vobj, original)
      vobj["_raw"] = original
      vobj["value"] = nil
      :nulled
    end

    def extract_number(s)
      s = s.to_s.strip.gsub(",", ".")
      # Reject formula-like strings
      return nil if s.match?(/\b(of|to|per|max|min|the|for)\b/i)
      return nil if s.match?(/[a-zA-Z]{3,}/) && !s.match?(/^[+-]?\d/)
      s = s.gsub(/[^0-9.\-+eE]/, "")
      return nil if s.empty?
      begin
        n = Float(s)
        n == n.to_i ? n.to_i : n
      rescue ArgumentError
        nil
      end
    end

    def parse_range(s)
      s = s.to_s.gsub(",", ".")
      # Match "X-Y", "X...Y", "X to Y", "-X/+Y"
      m = s.match(/(-?\d+\.?\d*)\s*(?:[-–—…\/]|\bto\b)\s*\+?(-?\d+\.?\d*)/i)
      return nil unless m
      [to_num(m[1]), to_num(m[2])]
    end

    def to_num(s)
      s = s.to_s.strip
      s.match?(/^-?\d+$/) ? s.to_i : s.to_f
    rescue
      nil
    end

    # ── Schema resolution ────────────────────────────────────────────

    def load_modules
      mods = {}
      return mods unless @modules_dir&.exist?
      Pathname.glob(@modules_dir + "*.yaml").each do |f|
        name = f.basename.to_s.sub(/\.yaml$/, "")
        mods[name] = YAML.load_file(f)
      end
      mods
    end

    def load_r_schema(r_str)
      path = @schema_dir + "#{r_str}.yaml"
      return nil unless path.exist?
      YAML.load_file(path)
    end

    def resolve_type(label, r_str)
      # Check R schema first (per-R constraints override module defaults)
      schema = load_r_schema(r_str)
      if schema
        aspect = schema.dig("scope", "aspects", label)
        return aspect["type"] if aspect && aspect["type"] && !aspect["_inherits_from_module"]

        r_spec = schema.dig("r_specific_aspects", label)
        return r_spec["type"] if r_spec && r_spec["type"]
      end
      # Check modules
      @modules.each_value do |mod|
        chars = mod["characteristics"] || {}
        spec = chars[label]
        return spec["type"] if spec && spec["type"]
      end
      nil
    end

    def resolve_enum_values(label, r_str)
      schema = load_r_schema(r_str)
      if schema
        aspect = schema.dig("scope", "aspects", label)
        return aspect["values"] if aspect && aspect["values"]
      end
      @modules.each_value do |mod|
        chars = mod["characteristics"] || {}
        spec = chars[label]
        return spec["values"] if spec && spec["values"]
      end
      nil
    end

    def resolve_structure(label, r_str)
      @modules.each_value do |mod|
        chars = mod["characteristics"] || {}
        spec = chars[label]
        return spec["structure"] if spec && spec["structure"]
      end
      nil
    end

    # ── I/O ──────────────────────────────────────────────────────────

    def read_yaml(path)
      YAML.load_file(path)
    end

    def write_yaml(path, data)
      path.write(YAML.dump(data))
    end
  end
end

# ─── CLI ──────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  ROOT = Pathname.new(File.expand_path("../..", __dir__))
  normalizer = OimlCs::Normalizer.new(schema_dir: ROOT + "schema")
  normalizer.normalize_all!(yaml_root: ROOT + "yaml")
  normalizer.report
end
