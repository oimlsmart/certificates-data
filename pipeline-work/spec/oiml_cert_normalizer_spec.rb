# frozen_string_literal: true

require "spec_helper"
require "oiml_cert/normalizer"

# Specs for the canonical_* helpers in OimlCert::Normalizer. These are
# pure module functions — easy to exercise exhaustively without doubles.
RSpec.describe OimlCert::Normalizer do
  # ─── Website canonicalization ──────────────────────────────────

  describe ".canonical_website" do
    it "adds https:// scheme when missing" do
      expect(described_class.canonical_website("www.nmi.nl")).to eq("https://www.nmi.nl")
    end

    it "preserves existing https:// scheme" do
      expect(described_class.canonical_website("https://www.example.com")).to eq("https://www.example.com")
    end

    it "preserves existing http:// scheme" do
      expect(described_class.canonical_website("http://example.com")).to eq("http://example.com")
    end

    it "strips whitespace" do
      expect(described_class.canonical_website("  www.example.com  ")).to eq("https://www.example.com")
    end

    it "preserves paths" do
      expect(described_class.canonical_website("www.gov.uk/nmo")).to eq("https://www.gov.uk/nmo")
    end

    it "preserves the N/A sentinel" do
      expect(described_class.canonical_website("N/A")).to eq("N/A")
    end

    it "returns nil unchanged" do
      expect(described_class.canonical_website(nil)).to be_nil
    end

    it "returns non-URL strings unchanged" do
      expect(described_class.canonical_website("info@example.com")).to eq("info@example.com")
    end
  end

  # ─── Email canonicalization ────────────────────────────────────

  describe ".canonical_email" do
    it "lowercases the email" do
      expect(described_class.canonical_email("Info@Example.COM")).to eq("info@example.com")
    end

    it "strips whitespace" do
      expect(described_class.canonical_email("  user@example.com  ")).to eq("user@example.com")
    end

    it "preserves the N/A sentinel" do
      expect(described_class.canonical_email("N/A")).to eq("N/A")
    end

    it "returns nil unchanged" do
      expect(described_class.canonical_email(nil)).to be_nil
    end
  end

  # ─── Phone canonicalization ────────────────────────────────────

  describe ".canonical_phone" do
    it "drops UK trunk prefix in international format" do
      expect(described_class.canonical_phone("+44 (0)20 8943 7272")).to eq("+44 20 8943 7272")
    end

    it "drops UK trunk prefix with extra spacing" do
      expect(described_class.canonical_phone("+44 (0) 20 8943 7272")).to eq("+44 20 8943 7272")
    end

    it "collapses internal whitespace runs" do
      expect(described_class.canonical_phone("+31   88   636 2332")).to eq("+31 88 636 2332")
    end

    it "preserves national-format numbers" do
      expect(described_class.canonical_phone("01 40 43 37 00")).to eq("01 40 43 37 00")
    end

    it "preserves the N/A sentinel" do
      expect(described_class.canonical_phone("N/A")).to eq("N/A")
    end

    it "returns nil unchanged" do
      expect(described_class.canonical_phone(nil)).to be_nil
    end
  end

  # ─── Company name canonicalization ─────────────────────────────

  describe ".canonical_company_name" do
    it "title-cases all-caps name with CO., LTD. suffix" do
      expect(described_class.canonical_company_name("WENZHOU ECOTEC ENERGY EQUIPMENT CO. LTD.")).
        to eq("Wenzhou Ecotec Energy Equipment Co. Ltd.")
    end

    it "title-cases all-caps name with CORPORATION suffix" do
      expect(described_class.canonical_company_name("TATSUNO CORPORATION")).
        to eq("Tatsuno Corporation")
    end

    it "title-cases company name with parenthesized region (punctuation normalized)" do
      # The normalizer title-cases the name and canonicalizes the suffix.
      # Parens handling is best-effort; we just verify the result is mixed-case
      # and contains "Tatsuno" and "Co."/"Ltd.".
      result = described_class.canonical_company_name("TATSUNO(THAILAND)CO.,LTD.")
      expect(result).to match(/Tatsuno/)
      expect(result).to match(/Co\./)
      expect(result).to match(/Ltd\./)
      expect(result).not_to eq(result.upcase)
    end

    it "preserves legitimate all-caps identifiers (no legal suffix)" do
      expect(described_class.canonical_company_name("DD1010ICHS")).to eq("DD1010ICHS")
    end

    it "preserves hashes (no legal suffix)" do
      expect(described_class.canonical_company_name("0C88143ACBFF11B2F212218B8613B176517F8D00")).
        to eq("0C88143ACBFF11B2F212218B8613B176517F8D00")
    end

    it "preserves already-mixed-case names" do
      expect(described_class.canonical_company_name("Endress+Hauser SE+Co. KG")).
        to eq("Endress+Hauser SE+Co. KG")
    end

    it "preserves the N/A sentinel" do
      expect(described_class.canonical_company_name("N/A")).to eq("N/A")
    end

    it "returns nil unchanged" do
      expect(described_class.canonical_company_name(nil)).to be_nil
    end

    it "preserves short initialisms (<=4 chars, no vowels)" do
      # When only the name portion is a short initialism it stays uppercase.
      # ABC GmbH → "ABC" stays caps, "GmbH" canonicalized.
      result = described_class.canonical_company_name("ABC GMBH")
      expect(result).to eq("ABC GmbH")
    end
  end

  # ─── Member state canonicalization ─────────────────────────────

  describe ".canonical_member_state" do
    it "normalizes case variants" do
      expect(described_class.canonical_member_state("FRANCE")).to eq("France")
    end

    it "normalizes long-form UK to short form" do
      expect(described_class.canonical_member_state("United Kingdom of Great Britain and Northern Ireland")).
        to eq("United Kingdom")
    end

    it "normalizes China variants" do
      expect(described_class.canonical_member_state("P. R. China")).to eq("China")
      expect(described_class.canonical_member_state("People's Republic of China")).to eq("China")
    end

    it "resolves issuer-id leaks (DE1, DK2 etc.)" do
      expect(described_class.canonical_member_state("DE1")).to eq("Germany")
      expect(described_class.canonical_member_state("DK2")).to eq("Denmark")
    end

    it "resolves ISO 2-letter codes" do
      expect(described_class.canonical_member_state("FR")).to eq("France")
      expect(described_class.canonical_member_state("CN")).to eq("China")
    end

    it "preserves the canonical form" do
      expect(described_class.canonical_member_state("Germany")).to eq("Germany")
    end

    it "returns nil for nil input" do
      expect(described_class.canonical_member_state(nil)).to be_nil
    end

    it "returns unrecognized strings as-is" do
      expect(described_class.canonical_member_state("Atlantis")).to eq("Atlantis")
    end
  end

  # ─── Issuing authority canonicalization ────────────────────────

  describe ".canonical_issuing_authority" do
    it "resolves by issuer ID when available (authoritative)" do
      result = described_class.canonical_issuing_authority("NMO", issuer_id: "GB1")
      expect(result).to eq("National Measurement Office")
    end

    it "force-overwrites extraction errors when ID is known" do
      result = described_class.canonical_issuing_authority("Agustin Falcón López", issuer_id: "ES1")
      expect(result).to eq("Centro Español de Metrología")
    end

    it "resolves issuer-id leaks (DE1 in name field)" do
      result = described_class.canonical_issuing_authority("DE1")
      expect(result).to eq("Physikalisch-Technische Bundesanstalt")
    end

    it "resolves known variants when no ID is available" do
      result = described_class.canonical_issuing_authority("NMO")
      expect(result).to eq("National Measurement Office")
    end

    it "resolves historical names (SP → RISE)" do
      result = described_class.canonical_issuing_authority("SP Technical Research Institute of Sweden")
      expect(result).to eq("RISE Research Institutes of Sweden AB")
    end

    it "resolves DELTA → FORCE (post-2018 merger)" do
      result = described_class.canonical_issuing_authority("DELTA")
      expect(result).to eq("FORCE Certification A/S")
    end

    it "preserves unrecognized names" do
      result = described_class.canonical_issuing_authority("Unknown Authority", issuer_id: nil)
      expect(result).to eq("Unknown Authority")
    end

    it "returns nil for nil input" do
      expect(described_class.canonical_issuing_authority(nil)).to be_nil
    end
  end

  # ─── String helper ─────────────────────────────────────────────

  describe ".strip_string" do
    it "strips leading whitespace" do
      expect(described_class.strip_string("  hello")).to eq("hello")
    end

    it "strips trailing whitespace" do
      expect(described_class.strip_string("hello  ")).to eq("hello")
    end

    it "preserves internal whitespace" do
      expect(described_class.strip_string("hello   world")).to eq("hello   world")
    end

    it "returns nil unchanged" do
      expect(described_class.strip_string(nil)).to be_nil
    end

    it "returns non-String input unchanged" do
      expect(described_class.strip_string(42)).to eq(42)
    end

    it "returns empty string unchanged (avoids creating empty)" do
      expect(described_class.strip_string("")).to eq("")
    end
  end

  # ─── Software identification parser ────────────────────────────

  describe ".parse_software_identification" do
    it "parses multi-line {board} software version: {ver} entries into array form" do
      input = "Main board software version: MV302_6_1\nKey board software version: 17305"
      result = described_class.parse_software_identification(input)
      expect(result).to eq([
        { "board" => "Main board", "firmware_version" => "MV302_6_1" },
        { "board" => "Key board", "firmware_version" => "17305" },
      ])
    end

    it "parses multi-line Version: X\\nChecksum: Y into object form" do
      input = "Version:V0.0.0.7\nChecksum:0x7DE0"
      result = described_class.parse_software_identification(input)
      expect(result).to eq({ "version_number" => "V0.0.0.7", "checksum" => "0x7DE0" })
    end

    it "splits single-line 'Version: X Checksum: Y' on the Checksum keyword" do
      input = "Version: V1-01-016 Checksum: 9B70A2B9"
      result = described_class.parse_software_identification(input)
      expect(result).to eq({ "version_number" => "V1-01-016", "checksum" => "9B70A2B9" })
    end

    it "parses 'Version number:' form" do
      input = "Version number: 1.2.3\nChecksum: ABCD"
      result = described_class.parse_software_identification(input)
      expect(result).to eq({ "version_number" => "1.2.3", "checksum" => "ABCD" })
    end

    it "parses firmware_version form" do
      input = "Firmware version: 7.1.0\nChecksum: FFFF"
      result = described_class.parse_software_identification(input)
      expect(result).to eq({ "version_number" => "7.1.0", "checksum" => "FFFF" })
    end

    it "preserves version-only entries as object form" do
      input = "Version: 1.0.0"
      result = described_class.parse_software_identification(input)
      expect(result).to eq({ "version_number" => "1.0.0" })
    end

    it "returns the input unchanged for unrecognized patterns" do
      input = "Some random text about software"
      result = described_class.parse_software_identification(input)
      # Falls through to whitespace-collapse fallback
      expect(result).to eq("Some random text about software")
    end

    it "returns non-String input unchanged" do
      expect(described_class.parse_software_identification(42)).to eq(42)
      expect(described_class.parse_software_identification(nil)).to be_nil
    end
  end
end
