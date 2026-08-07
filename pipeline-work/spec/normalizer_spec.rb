# frozen_string_literal: true

require "spec_helper"
require "oiml_cs/normalizer"

RSpec.describe OimlCs::Normalizer do
  let(:schema_dir) { ROOT + "schema" }
  let(:normalizer) { described_class.new(schema_dir: schema_dir) }

  # ─── Enum normalization ─────────────────────────────────────────

  describe "enum normalization" do
    it "fixes case: 'Non-condensing' → 'non-condensing'" do
      vobj = { "value" => "Non-condensing" }
      allowed = %w[CH NH SH non-condensing condensing]
      result = normalizer.send(:normalize_enum, vobj, allowed)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to eq("non-condensing")
    end

    it "nulls values that can't be matched" do
      vobj = { "value" => "random junk text" }
      allowed = %w[CH NH SH]
      result = normalizer.send(:normalize_enum, vobj, allowed)
      expect(result).to eq(:nulled)
      expect(vobj["value"]).to be_nil
      expect(vobj["_raw"]).to eq("random junk text")
    end

    it "handles array values (enum_multi)" do
      vobj = { "value" => ["III", "IIII"] }
      allowed = %w[I II III IIII]
      result = normalizer.send(:normalize_enum_multi, vobj, allowed)
      expect(result).to be_nil # already canonical
    end
  end

  # ─── Numeric normalization ──────────────────────────────────────

  describe "numeric normalization" do
    it "extracts number from compound string '3,5bar'" do
      vobj = { "value" => "3,5bar" }
      result = normalizer.send(:normalize_numeric, vobj)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to eq(3.5)
    end

    it "nulls formula references like '≥20% of Max'" do
      vobj = { "value" => "≥20% of Max" }
      result = normalizer.send(:normalize_numeric, vobj)
      expect(result).to eq(:nulled)
      expect(vobj["value"]).to be_nil
    end

    it "unwraps nested value-objects" do
      vobj = { "value" => { "value" => 42, "unit_symbol" => "kg" } }
      result = normalizer.send(:normalize_numeric, vobj)
      expect(vobj["value"]).to eq(42)
    end

    it "extracts from range dict {min: 5}" do
      vobj = { "value" => { "min" => 5, "max" => nil } }
      result = normalizer.send(:normalize_numeric, vobj)
      expect(vobj["value"]).to eq(5)
    end
  end

  # ─── Range normalization ────────────────────────────────────────

  describe "range normalization" do
    it "parses '10-40' into {min:10, max:40}" do
      vobj = { "value" => "10-40" }
      result = normalizer.send(:normalize_range, vobj)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to eq({ "min" => 10, "max" => 40 })
    end

    it "parses '-10/+40' into {min:-10, max:40}" do
      vobj = { "value" => "-10/+40" }
      result = normalizer.send(:normalize_range, vobj)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to eq({ "min" => -10, "max" => 40 })
    end

    it "accepts bare number as degenerate range" do
      vobj = { "value" => 230 }
      result = normalizer.send(:normalize_range, vobj)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to eq({ "min" => 230, "max" => 230 })
    end

    it "unwraps array-wrapped range dict" do
      vobj = { "value" => [{ "min" => 100, "max" => 240 }] }
      result = normalizer.send(:normalize_range, vobj)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to eq({ "min" => 100, "max" => 240 })
    end

    it "nulls genuinely unparseable strings" do
      vobj = { "value" => "not a range at all" }
      result = normalizer.send(:normalize_range, vobj)
      expect(result).to eq(:nulled)
      expect(vobj["value"]).to be_nil
    end
  end

  # ─── Compound normalization ─────────────────────────────────────

  describe "compound normalization" do
    it "decomposes 'M1, E1, H3' into structured hash" do
      structure = {
        "mechanical" => { "type" => "enum", "values" => %w[M1 M2 M3] },
        "electromagnetic" => { "type" => "enum", "values" => %w[E1 E2 E3] },
        "humidity" => { "type" => "enum", "values" => %w[H1 H2 H3] },
      }
      vobj = { "value" => "M1, E1, H3" }
      result = normalizer.send(:normalize_compound, vobj, structure)
      expect(result).to eq(:changed)
      expect(vobj["value"]).to include("mechanical" => "M1", "electromagnetic" => "E1", "humidity" => "H3")
    end

    it "decomposes 'M3/E2+E31' format" do
      structure = {
        "mechanical" => { "type" => "enum" },
        "electromagnetic" => { "type" => "enum" },
      }
      vobj = { "value" => "M3/E2+E31" }
      result = normalizer.send(:normalize_compound, vobj, structure)
      expect(result).to eq(:changed)
      expect(vobj["value"]["mechanical"]).to eq("M3")
    end
  end

  # ─── Int normalization ──────────────────────────────────────────

  describe "int normalization" do
    it "truncates whole-number float to int" do
      vobj = { "value" => 3000.0 }
      result = normalizer.send(:normalize_int, vobj)
      expect(vobj["value"]).to eq(3000)
    end
  end
end
