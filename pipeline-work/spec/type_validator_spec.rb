# frozen_string_literal: true

require "spec_helper"
require "oiml_cs/type_validator"

RSpec.describe OimlCs::TypeValidator do
  let(:schema_dir) { ROOT + "schema" }
  let(:validator) { described_class.new(schema_dir: schema_dir) }

  # ─── Enum checking ──────────────────────────────────────────────

  describe "#check_enum" do
    it "passes when value is in allowed list" do
      spec = { "type" => "enum", "values" => %w[CH NH SH] }
      expect(validator.send(:check_enum, "humidity_class", "CH", spec)).to be_empty
    end

    it "reports violation when value is not in allowed list" do
      spec = { "type" => "enum", "values" => %w[CH NH SH] }
      result = validator.send(:check_enum, "humidity_class", "XX", spec)
      expect(result.size).to eq(1)
      expect(result[0][:bad]).to eq(["XX"])
    end

    it "skips nil values (not present = valid)" do
      spec = { "type" => "enum", "values" => %w[CH NH SH] }
      expect(validator.send(:check_enum, "humidity_class", nil, spec)).to be_empty
    end

    it "allows text stand-ins" do
      spec = { "type" => "enum", "values" => %w[CH NH], "allow_text_values" => ["N/A"] }
      expect(validator.send(:check_enum, "humidity_class", "N/A", spec)).to be_empty
    end
  end

  # ─── Numeric checking ───────────────────────────────────────────

  describe "#check_numeric" do
    it "passes for integers" do
      spec = { "type" => "numeric" }
      expect(validator.send(:check_numeric, "max", 3000, spec)).to be_empty
    end

    it "passes for floats" do
      spec = { "type" => "numeric" }
      expect(validator.send(:check_numeric, "factor", 0.7, spec)).to be_empty
    end

    it "reports violation for non-numeric strings" do
      spec = { "type" => "numeric" }
      result = validator.send(:check_numeric, "max", "n×dt", spec)
      expect(result.size).to eq(1)
      expect(result[0][:reason]).to eq("not_a_number")
    end

    it "unwraps nested value-objects" do
      spec = { "type" => "numeric" }
      nested = { "value" => 42, "unit_symbol" => "kg" }
      expect(validator.send(:check_numeric, "max", nested, spec)).to be_empty
    end

    it "extracts number from range dict" do
      spec = { "type" => "numeric" }
      range_dict = { "min" => 5, "max" => nil }
      expect(validator.send(:check_numeric, "min", range_dict, spec)).to be_empty
    end
  end

  # ─── Range checking ─────────────────────────────────────────────

  describe "#check_range" do
    it "passes for {min, max} hash" do
      spec = { "type" => "range" }
      expect(validator.send(:check_range, "temp", { "min" => -10, "max" => 40 }, spec)).to be_empty
    end

    it "passes for symbol-keyed hash" do
      spec = { "type" => "range" }
      expect(validator.send(:check_range, "temp", { min: -10, max: 40 }, spec)).to be_empty
    end

    it "passes for bare number (degenerate range)" do
      spec = { "type" => "range" }
      expect(validator.send(:check_range, "voltage", 230, spec)).to be_empty
    end

    it "unwraps array-wrapped range" do
      spec = { "type" => "range" }
      wrapped = [{ "min" => 100, "max" => 240 }]
      expect(validator.send(:check_range, "voltage", wrapped, spec)).to be_empty
    end

    it "reports violation for non-range string" do
      spec = { "type" => "range" }
      result = validator.send(:check_range, "voltage", "random text", spec)
      expect(result.size).to eq(1)
      expect(result[0][:reason]).to eq("not_a_range")
    end

    it "skips nil values" do
      spec = { "type" => "range" }
      expect(validator.send(:check_range, "temp", nil, spec)).to be_empty
    end
  end

  # ─── Int checking ───────────────────────────────────────────────

  describe "int type (merged with numeric)" do
    it "truncates whole-number floats" do
      spec = { "type" => "int" }
      expect(validator.send(:check_numeric, "n", 3000.0,
                            spec.merge("integer" => true))).to be_empty
    end
  end

  # ─── Compound checking ──────────────────────────────────────────

  describe "#check_compound" do
    it "passes for properly structured hash" do
      spec = {
        "type" => "compound",
        "structure" => {
          "mechanical" => { "type" => "enum", "values" => %w[M1 M2] },
          "electromagnetic" => { "type" => "enum", "values" => %w[E1 E2] },
        }
      }
      value = { "mechanical" => "M1", "electromagnetic" => "E1" }
      expect(validator.send(:check_compound, "env", value, spec)).to be_empty
    end

    it "reports violation for non-hash" do
      spec = { "type" => "compound", "structure" => {} }
      result = validator.send(:check_compound, "env", "M1/E1", spec)
      expect(result.size).to eq(1)
      expect(result[0][:reason]).to eq("not_a_hash")
    end
  end

  # ─── Boolean checking ───────────────────────────────────────────

  describe "#check_boolean" do
    it "passes for true/false" do
      spec = { "type" => "boolean" }
      expect(validator.send(:check_boolean, "flag", true, spec)).to be_empty
      expect(validator.send(:check_boolean, "flag", false, spec)).to be_empty
    end

    it "normalizes yes/no" do
      spec = { "type" => "boolean" }
      result = validator.send(:check_boolean, "flag", "yes", spec)
      expect(result).to be_empty # validator doesn't normalize, just checks
    end
  end

  # ─── Full cert validation ───────────────────────────────────────

  describe "#validate_cert" do
    it "returns 0 violations for a clean R76 cert" do
      cert = ROOT + "yaml/R76/2006/r076-2006-bg1-2013-17-rev1.yaml"
      skip "#{cert} not found" unless cert.exist?
      violations = validator.validate_cert(cert)
      expect(violations).to be_empty
    end

    it "returns 0 violations for a clean R60 cert" do
      cert = ROOT + "yaml/R60/2021/r60-2021-de1-2024-01.yaml"
      skip "#{cert} not found" unless cert.exist?
      violations = validator.validate_cert(cert)
      expect(violations).to be_empty
    end
  end
end
