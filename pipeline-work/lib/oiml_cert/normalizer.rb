# frozen_string_literal: true

require "yaml"

module OimlCert
  # Normalizer: converts surface forms in cert data to canonical tokens.
  #
  # Mechanical transformation — no judgment calls, no per-cert review.
  # If a surface form is missing from a map, validation flags it and the
  # map gets extended.
  module Normalizer
    NA = "N/A"

    # ── Synonym maps ──────────────────────────────────────────────────

    # Canonical member_state names. Maps every observed surface form
    # to the official OIML short name. Drives the certificate.member_state
    # canonicalization pass.
    MEMBER_STATE_CANONICAL = {
      # Direct canonical (no-op when already canonical)
      "France"                                                  => "France",
      "Czech Republic"                                          => "Czech Republic",
      "The Netherlands"                                         => "The Netherlands",
      "Netherlands"                                             => "The Netherlands",
      "Denmark"                                                 => "Denmark",
      "United Kingdom of Great Britain and Northern Ireland"    => "United Kingdom",
      "United Kingdom"                                          => "United Kingdom",
      "Switzerland"                                             => "Switzerland",
      "Germany"                                                 => "Germany",
      "Italy"                                                   => "Italy",
      "China"                                                   => "China",
      "Spain"                                                   => "Spain",
      "Sweden"                                                  => "Sweden",
      "Norway"                                                  => "Norway",
      "Slovakia"                                                => "Slovakia",
      "Japan"                                                   => "Japan",
      "Australia"                                               => "Australia",
      "Russia"                                                  => "Russia",
      # Surface variants observed in actual cert data
      "FRANCE"                                                  => "France",
      "France "                                                 => "France",
      "P. R. China"                                             => "China",
      "People's Republic of China"                              => "China",
      "PRC"                                                     => "China",
      "The Russian Federation"                                  => "Russia",
      "Russian Federation"                                      => "Russia",
      "Great Britain"                                           => "United Kingdom",
      "UK"                                                      => "United Kingdom",
      "Holland"                                                 => "The Netherlands",
      "Czech"                                                   => "Czech Republic",
      "Czechia"                                                 => "Czech Republic",
      "Republic of Korea"                                       => "South Korea",
      "South Korea"                                             => "South Korea",
      # Issuer-id leaks (DE1, DK2 etc. ended up in member_state field)
      "DE1" => "Germany", "DE2" => "Germany", "DE3" => "Germany",
      "DK1" => "Denmark", "DK2" => "Denmark", "DK3" => "Denmark",
      "NL1" => "The Netherlands", "NL2" => "The Netherlands",
      "FR1" => "France", "FR2" => "France",
      "GB1" => "United Kingdom", "GB2" => "United Kingdom",
      "CZ1" => "Czech Republic",
      "CH1" => "Switzerland", "CH2" => "Switzerland",
      "SE1" => "Sweden",
      "IT1" => "Italy",
      "ES1" => "Spain",
      "CN1" => "China", "CN2" => "China",
      "US1" => "United States",
      "JP1" => "Japan",
      # ISO 2-letter codes
      "FR" => "France", "CZ" => "Czech Republic", "NL" => "The Netherlands",
      "DK" => "Denmark", "GB" => "United Kingdom", "CH" => "Switzerland",
      "DE" => "Germany", "IT" => "Italy", "TR" => "Turkey",
      "CN" => "China", "ES" => "Spain", "US" => "United States",
      "PL" => "Poland", "SE" => "Sweden", "NO" => "Norway", "FI" => "Finland",
      "BE" => "Belgium", "AT" => "Austria", "PT" => "Portugal", "IE" => "Ireland",
      "GR" => "Greece", "SI" => "Slovenia", "HR" => "Croatia", "HU" => "Hungary",
      "RO" => "Romania", "BG" => "Bulgaria", "SK" => "Slovakia", "RU" => "Russia",
      "LT" => "Lithuania", "LV" => "Latvia", "EE" => "Estonia", "IS" => "Iceland",
      "LU" => "Luxembourg", "MT" => "Malta", "CY" => "Cyprus", "AU" => "Australia",
      "JP" => "Japan", "KR" => "South Korea",
    }.freeze

    # Normalize a member_state surface form to the canonical short name.
    # Returns nil for unrecognized values (the caller may keep the original).
    def self.canonical_member_state(raw)
      return nil if raw.nil?
      s = raw.to_s.strip
      return nil if s.empty?
      MEMBER_STATE_CANONICAL[s] || MEMBER_STATE_CANONICAL[s.upcase] || s
    end

    # Canonical issuing authority name per OIML issuer ID (NL1, DE1, etc.).
    # The ID is stable across name changes (corporate renames, translations,
    # extraction variants). When issuing_authority.name doesn't match the
    # canonical form for the cert's oiml_issuer_id, we rewrite it.
    ISSUING_AUTHORITY_BY_ID = {
      "AU1" => "National Measurement Institute Australia",
      "CH1" => "Federal Institute of Metrology METAS",
      "CN1" => "Office of OIML Affairs, General Administration of Quality Supervision, Inspection and Quarantine",
      "CN2" => "National Institute of Metrology, China",
      "CZ1" => "Czech Metrology Institute",
      "DE1" => "Physikalisch-Technische Bundesanstalt",
      "DK2" => "FORCE Certification A/S",
      "DK3" => "FORCE Certification A/S", # DELTA merged into FORCE in 2018
      "ES1" => "Centro Español de Metrología",
      "FR2" => "Laboratoire National de Métrologie et d'Essais",
      "GB1" => "National Measurement Office", # Historical name used across most UK certs
      "IT1" => "Istituto Nazionale di Ricerca Metrologica",
      "IT2" => "Istituto Nazionale di Ricerca Metrologica",
      "JP1" => "National Metrology Institute of Japan, AIST",
      "NL1" => "NMi Certin B.V.",
      "NO1" => "Justervesenet",
      "RU1" => "VNIIMS",
      "SE1" => "RISE Research Institutes of Sweden AB",
      "SK1" => "Slovak Legal Metrology",
      "US1" => "National Institute of Standards and Technology",
    }.freeze

    # Issuer-id leak patterns (the issuer ID ended up in the name field).
    ISSUER_ID_LEAK = /\A([A-Z]{2})\d+\z/.freeze

    # Common typo / surface variants per canonical name. Maps variant → canonical.
    ISSUING_AUTHORITY_VARIANTS = {
      # CH1 variants
      "Federal Institute of Metrologie METAS"                                        => "Federal Institute of Metrology METAS",
      "Federal Institute of Metrology METAS Conformity Evaluation Body METAS-Cert"   => "Federal Institute of Metrology METAS",
      "Federal Office of Metrology METAS Certification Body METAS-Cert"              => "Federal Institute of Metrology METAS",
      # FR2 variants — drop the suffix; LNE abbreviation stays as the full form
      "Laboratoire National de Métrologie et d'Essais Certification Instruments de Mesure" => "Laboratoire National de Métrologie et d'Essais",
      "LNE"                                                                           => "Laboratoire National de Métrologie et d'Essais",
      # GB1 variants — UK NMIs consolidated under National Measurement Office historically
      "NMO"                                                                                          => "National Measurement Office",
      "National Measurement & Regulation Office"                                                    => "National Measurement Office",
      "National Measurement and Regulation Office"                                                  => "National Measurement Office",
      "National Weights and Measures Laboratory"                                                    => "National Measurement Office",
      "National Weights and Measures Laboratory (Part of the National Measurement Office)"          => "National Measurement Office",
      "Office for Product Safety and Standards"                                                     => "National Measurement Office",
      "OIML Issuing Authority NMO"                                                                  => "National Measurement Office",
      # SE1 — SP renamed to RISE in 2016
      "SP Technical Research Institute of Sweden"                                                   => "RISE Research Institutes of Sweden AB",
      # DK3 — DELTA merged into FORCE Certification in 2018; canonicalize to current
      "DELTA"                                                                                       => "FORCE Certification A/S",
      # DE1 — suffix variant
      "Physikalisch-Technische Bundesanstalt, Conformity Assessment Body"                          => "Physikalisch-Technische Bundesanstalt",
      # JP1 — spacing variants
      "National Metrology Institute of Japan/National Institute of Advanced Industrial Science and Technology(NMIJ/AIST)" => "National Metrology Institute of Japan, AIST",
      "National Metrology Institute of Japan /National Institute of Advanced Industrial Science and Technology (NMIJ/AIST)" => "National Metrology Institute of Japan, AIST",
      # NO1 — alternative form
      "Justervesenet, Norwegian Metrology Service" => "Justervesenet",
    }.freeze

    # Resolve an issuing authority name to its canonical form, using the
    # certificate's oiml_issuer_id (authoritative) when available, falling
    # back to the variant map.
    def self.canonical_issuing_authority(name, issuer_id: nil)
      return nil if name.nil?
      s = name.to_s.strip
      # Issuer-id leak (DE1, IT2, etc. in the name field) → resolve via ID
      if (m = s.match(ISSUER_ID_LEAK)) && ISSUING_AUTHORITY_BY_ID.key?(m[1] + s[/\d+/])
        return ISSUING_AUTHORITY_BY_ID[m[1] + s[/\d+/]]
      end
      # ID-driven canonicalization (most reliable). When we know the
      # issuer_id, the canonical name from the registry is authoritative —
      # overwrite the extracted name. This catches extraction errors where
      # a person name, manufacturer name, or abbreviation landed in the
      # issuing_authority.name field.
      if issuer_id && (canonical = ISSUING_AUTHORITY_BY_ID[issuer_id.to_s])
        return canonical
      end
      # No ID available — try the variant map
      ISSUING_AUTHORITY_VARIANTS[s] || s
    end

    def self.canonical_issuer_id_leak?(value)
      !!value.to_s.match(ISSUER_ID_LEAK)
    end

    # Canonicalize a website URL: ensure scheme, lowercase host, strip
    # trailing slash on path-less URLs. Preserves user-facing paths.
    #
    # Examples:
    #   "www.nmi.nl"              → "https://www.nmi.nl"
    #   "HTTP://EXAMPLE.COM/"     → "http://example.com"
    #   "https://example.com/x/"  → "https://example.com/x/"   (path kept)
    #   "N/A"                     → "N/A"                      (sentinel kept)
    def self.canonical_website(raw)
      return raw if raw.nil?
      s = raw.to_s.strip
      return raw if s.empty? || s == NA
      return s if s =~ /\Ahttps?:\/\//i
      return "https://#{s}" if s =~ /\A(www\.|[a-z][a-z0-9\-]*\.[a-z]{2,})/i
      # Anything else (e.g. email-shaped, malformed) — leave as-is
      s
    end

    # Canonicalize an email: lowercase, strip whitespace. Preserves N/A.
    def self.canonical_email(raw)
      return raw if raw.nil?
      s = raw.to_s.strip
      return raw if s.empty? || s == NA
      s.downcase
    end

    # Canonicalize a phone number: collapse whitespace runs, drop the UK
    # trunk-prefix marker `(0)` used in international format. Preserves
    # N/A and non-numeric values.
    #
    # Examples:
    #   "+31 88 636 2332"      → "+31 88 636 2332"  (already canonical)
    #   "+31 88 6362332"       → "+31 88 636 2332"  (only if input had explicit grouping)
    #   "+44 (0)20 8943 7272"  → "+44 20 8943 7272"
    #   "+44 (0) 20 8943 7272" → "+44 20 8943 7272"
    #   "01 40 43 37 00"       → "01 40 43 37 00"   (national format kept)
    #
    # Note: we do NOT insert grouping into ungrouped numbers — too risky
    # (country-specific rules). We only normalize obvious surface forms.
    def self.canonical_phone(raw)
      return raw if raw.nil?
      s = raw.to_s.strip
      return raw if s.empty? || s == NA
      # Drop UK trunk prefix: "+CC (0) area" → "+CC area"
      s = s.sub(/(\+\d{1,3})\s*\(0\)\s*/, '\1 ')
      # Collapse internal whitespace runs to single space
      s = s.gsub(/\s+/, " ").strip
      s
    end

    # Strip leading/trailing whitespace from a free-form string. Preserves
    # N/A, nil, and embedded whitespace (which may be meaningful).
    def self.strip_string(raw)
      return raw if raw.nil?
      return raw unless raw.is_a?(String)
      s = raw.strip
      s.empty? ? raw : s
    end

    # Legal-entity suffixes that indicate a string is a company name.
    # When the entire name is uppercase and ends in one of these, the
    # name portion before the suffix is title-cased (the suffix itself
    # remains in canonical form: "Co.", "Ltd.", "GmbH", etc.).
    COMPANY_SUFFIXES = %w[
      CO CO. CO., LTD LTD. LTD., LIMITED
      CORPORATION CORP CORP. INC INC. INC.,
      GMBH GmbH\ &\ Co.\ KG SE\ &\ Co.\ KG SE
      S.A. SA S.R.L. SRL S.P.A. SPA S.r.l. Srl
      B.V. BV B.V., AG OY KK PTY LTD
      PRIVATE\ LIMITED PVT.\ LTD
    ].freeze

    # Canonical form of common company suffixes (uppercase → canonical).
    COMPANY_SUFFIX_CANONICAL = {
      "CO" => "Co.", "CO." => "Co.", "CO.," => "Co.",
      "LTD" => "Ltd.", "LTD." => "Ltd.", "LTD.," => "Ltd.",
      "LIMITED" => "Ltd.",
      "CORPORATION" => "Corporation", "CORP" => "Corp.", "CORP." => "Corp.",
      "INC" => "Inc.", "INC." => "Inc.", "INC.," => "Inc.",
      "GMBH" => "GmbH",
      "AG" => "AG",
      "B.V." => "B.V.", "BV" => "B.V.",
      "S.A." => "S.A.", "SA" => "S.A.",
      "S.R.L." => "S.r.l.", "SRL" => "S.r.l.",
      "S.P.A." => "S.p.A.", "SPA" => "S.p.A.",
      "OY" => "Oy", "KK" => "K.K.",
    }.freeze

    # Canonicalize a company / organization name. Title-cases names that
    # are entirely uppercase and end in a legal-entity suffix; leaves
    # legitimate all-caps identifiers (model codes, hashes) untouched.
    # Also normalizes spacing around parentheses and commas.
    def self.canonical_company_name(raw)
      return raw if raw.nil?
      s = raw.to_s.strip
      return raw if s.empty? || s == NA
      # Collapse internal whitespace runs
      s = s.gsub(/\s+/, " ")
      # Normalize punctuation: "(thailand)" → " (Thailand) " patterns
      s = s.gsub(/\s*[(\[]\s*/, " (").gsub(/\s*[)\]]\s*/, ") ")
      s = s.gsub(/\s*,\s*/, ", ").gsub(/,\s*\./, ",.")
      s = s.strip
      # Detect all-caps company name with legal suffix
      words = s.split(/\s+/)
      return s unless words.length >= 2
      return s unless words.all? { |w| w == w.upcase }
      # Find the suffix start (last consecutive run of suffix words)
      suffix_start = words.length
      words.reverse.each do |w|
        stripped = w.sub(/[.,]+$/, "")
        if COMPANY_SUFFIX_CANONICAL.key?(stripped) || COMPANY_SUFFIX_CANONICAL.key?(w)
          suffix_start -= 1
        else
          break
        end
      end
      return s if suffix_start == words.length # no suffix found
      return s if suffix_start.zero?            # only suffix, nothing to title-case
      # Title-case the name portion, canonicalize each suffix word
      name_part = words[0...suffix_start].map { |w| titlecase_word(w) }.join(" ")
      suffix_part = words[suffix_start..].map do |w|
        stripped = w.sub(/[.,]+$/, "")
        canon = COMPANY_SUFFIX_CANONICAL[stripped] || COMPANY_SUFFIX_CANONICAL[w] || w
        # Preserve trailing period if original had one and canonical doesn't
        canon
      end.join(" ")
      result = "#{name_part} #{suffix_part}".strip
      # Collapse double spaces from suffix join
      result.gsub(/\s+/, " ")
    end

    # Title-case a single word, preserving likely acronyms (short tokens
    # that were already all-uppercase in the source). Conservative —
    # leans on not over-capitalizing.
    def self.titlecase_word(word)
      return word if word.length <= 1
      # Already all-uppercase + short → treat as initialism (IBM, ABC, SAP)
      return word if word.length <= 4 && word == word.upcase && word =~ /[A-Z]/
      # Otherwise standard title case: first letter cap, rest lower
      word[0].upcase + word[1..].downcase
    end

    # Parse a multi-line software_identification string into the
    # structured form per the SoftwareIdentification schema. Returns
    # the input unchanged when no parseable pattern is recognized.
    #
    # Recognized patterns:
    #   - "{board} software version: {ver}" lines  → Array form
    #   - "Version number: X\nChecksum: Y"          → Object form
    #   - "Version: X\nChecksum: Y"                 → Object form
    #   - Single-line "Version: X Checksum: Y"      → Object form (split on keyword)
    #   - Mixed prose + bullet items                → String (collapse whitespace)
    def self.parse_software_identification(raw)
      return raw unless raw.is_a?(String)

      raw_lines = raw.split(/\n+/).map(&:strip).reject(&:empty?)
      return raw if raw_lines.empty?

      # Pattern 1 (no preprocessing): each line is "{board} software version: {ver}".
      # Check this first — preprocessing would break it by splitting on "version:".
      board_version_pairs = raw_lines.map do |line|
        m = line.match(/\A(.*?)\s+software\s+version\s*:\s*(.+)\z/i)
        m && { "board" => m[1], "firmware_version" => m[2] }
      end
      if board_version_pairs.all? && raw_lines.length > 1
        return board_version_pairs
      end

      # Pre-process: insert newlines before "Checksum:" / "Version:" keywords
      # so a single-line "Version: X Checksum: Y" splits into two virtual lines.
      preprocessed = raw
        .gsub(/(?<=[^\n])\s*(Checksum)\s*:/i, "\n\\1:")
        .gsub(/(?<=[^\n])\s*(Version(?:\s+number)?)\s*:/i, "\n\\1:")

      return raw if preprocessed == raw && !raw.include?("\n") &&
                    raw !~ /\A\s*\-?\s*(?:Version|Checksum|board)/i

      lines = preprocessed.split(/\n+/).map(&:strip).reject(&:empty?)
      return raw if lines.empty?

      # Pattern 2: lines contain "Version [number]: X" and/or "Checksum: Y".
      # Use specific anchored regex per line so "Version: X Checksum: Y"
      # doesn't capture both into version_number.
      version_match = lines.filter_map { |l| l.match(/\A[-:]?\s*Version(?:\s+number)?\s*[:=]\s*(.+?)\s*\z/i) }.first
      firmware_match = lines.filter_map { |l| l.match(/\A[-:]?\s*firmware(?:\s+version)?\s*[:=]\s*(.+?)\s*\z/i) }.first
      checksum_match = lines.filter_map { |l| l.match(/\A[-:]?\s*[Cc]hecksum\s*[:=]\s*(.+?)\s*\z/) }.first

      if version_match || firmware_match || checksum_match
        obj = {}
        obj["version_number"] = (firmware_match || version_match)[1].strip if firmware_match || version_match
        obj["checksum"] = checksum_match[1].strip if checksum_match
        return obj unless obj.empty?
      end

      # Pattern 3: component sections separated by lines without colons
      # Best-effort: keep as string but collapse whitespace
      raw.gsub(/\s+/, " ").strip
    end

    LOAD_CELL_CHARACTERIZATION = {
      "analog_passive"                         => "analog_passive",
      "analog_active"                          => "analog_active",
      "digital_passive"                        => "digital_passive",
      "digital_active"                         => "digital_active",
      "Analog load cell"                       => "analog_passive",
      "Analogue-passive"                       => "analog_passive",
      "Analog-passive"                         => "analog_passive",
      "Analog-passive load cell"               => "analog_passive",
      "analogue-passive"                       => "analog_passive",
      "analog-passive"                         => "analog_passive",
      "Analog-active"                          => "analog_active",
      "analogue-active"                        => "analog_active",
      "analog-active"                          => "analog_active",
      "Analog-active load cell"                => "analog_active",
      "Digital load cell"                      => "digital_active",
      "digital load cell"                      => "digital_active",
      "Digital load cell with data processing" => "digital_active",
      "Digital-passive"                        => "digital_passive",
      "digital-passive"                        => "digital_passive",
      "Digital-active"                         => "digital_active",
      "digital-active"                         => "digital_active",
      "Digital load cell with data processing capabilities" => "digital_active",
      "Not applicable"                         => NA,
    }.freeze

    HUMIDITY_MARKING = {
      "CH" => "CH", "NH" => "NH", "SH" => "SH",
      "ch" => "CH", "nh" => "NH", "sh" => "SH",
    }.freeze

    CLIMATIC_CLASS = {
      "H1" => "H1", "H2" => "H2", "H3" => "H3",
      "h1" => "H1", "h2" => "H2", "h3" => "H3",
      "condensing"          => "H2",
      "non-condensing"      => "H1",
      "non-condensing, indoor" => "H1",
      "condensing, outdoor" => "H3",
    }.freeze

    MECHANICAL_CLASS = {
      "M1" => "M1", "M2" => "M2", "M3" => "M3",
      "m1" => "M1", "m2" => "M2", "m3" => "M3",
    }.freeze

    EM_CLASS = {
      "E1" => "E1", "E2" => "E2", "E3" => "E3",
      "e1" => "E1", "e2" => "E2", "e3" => "E3",
    }.freeze

    CURRENT_TYPE = {
      "AC"    => "AC",
      "DC"    => "DC",
      "AC/DC" => "AC/DC",
      "AC_DC" => "AC/DC",
      "AC-DC" => "AC/DC",
      "VAC"   => "AC",
      "VDC"   => "DC",
      "V AC"  => "AC",
      "V DC"  => "DC",
    }.freeze

    # R61 instrument types — surface forms → canonical tokens
    R61_INSTRUMENT_TYPE = {
      "automatic_gravimetric_filling_instrument"                          => "automatic_gravimetric_filling_instrument",
      "Automatic Gravimetric filling instrument"                          => "automatic_gravimetric_filling_instrument",
      "Automatic Gravimetric Filling Instrument"                          => "automatic_gravimetric_filling_instrument",
      "automatic gravimetric filling instrument"                          => "automatic_gravimetric_filling_instrument",
      "cumulative_weighing_instrument"                                    => "cumulative_weighing_instrument",
      "Cumulative weighing instrument"                                    => "cumulative_weighing_instrument",
      "cumulative weighing instrument"                                    => "cumulative_weighing_instrument",
      "selective_combination_weighing_instrument"                         => "selective_combination_weighing_instrument",
      "Selective combination weighing instrument"                         => "selective_combination_weighing_instrument",
      "selective combination weighing instrument"                         => "selective_combination_weighing_instrument",
      "subtractive_weighing_instrument"                                   => "subtractive_weighing_instrument",
      "Subtractive weighing instrument"                                   => "subtractive_weighing_instrument",
      "subtractive weighing instrument"                                   => "subtractive_weighing_instrument",
      "multi_load_agfi"                                                   => "multi_load_agfi",
      "Multi-load AGFI"                                                   => "multi_load_agfi",
      "weighing_transmitter"                                              => "weighing_transmitter",
      "Weighing transmitter"                                              => "weighing_transmitter",
      "Weighing transmitter for automatic gravimetric filling instruments"=> "weighing_transmitter",
      "multihead_weigher"                                                 => "multihead_weigher",
      "Multihead weigher"                                                 => "multihead_weigher",
      "load_cell_digitizing_unit"                                         => "load_cell_digitizing_unit",
      "Load cell digitizing unit"                                         => "load_cell_digitizing_unit",
      "complete_filling_instrument"                                       => "automatic_gravimetric_filling_instrument",
      "Complete filling instrument"                                       => "automatic_gravimetric_filling_instrument",
    }.freeze

    # R61 method of operation — surface forms → canonical tokens
    R61_METHOD_OF_OPERATION = {
      "filling_by_one_weighing_cycle"               => "filling_by_one_weighing_cycle",
      "Filling by one weighing cycle"               => "filling_by_one_weighing_cycle",
      "filling by one weighing cycle"               => "filling_by_one_weighing_cycle",
      "single_weigh_cycle"                          => "filling_by_one_weighing_cycle",
      "cumulative_weighing"                         => "cumulative_weighing",
      "Cumulative weighing"                         => "cumulative_weighing",
      "cumulative weighing"                         => "cumulative_weighing",
      "cummulative filling"                         => "cumulative_weighing",
      "cummulative weighing"                        => "cumulative_weighing",
      "selective_combination_weighing"              => "selective_combination_weighing",
      "Selective combination weighing"              => "selective_combination_weighing",
      "selective combination weighing"              => "selective_combination_weighing",
      "subtractive_weighing"                        => "subtractive_weighing",
      "Subtractive weighing"                        => "subtractive_weighing",
      "subtractive weighing"                        => "subtractive_weighing",
    }.freeze

    # Normalize any X(x) / Ref(x) accuracy class token — converts
    # European comma decimals `Ref(0,2)` → canonical dot form `Ref(0.2)`.
    # Strips leading prefix like "OIML R 76 or OIML R 61 " when present.
    def self.normalize_ref_x_token(raw)
      return NA if raw.nil? || raw.to_s.empty?
      s = raw.to_s
      # Strip common prefix like "OIML R 76 or OIML R 61 "
      s = s.sub(/^OIML\s+R\s+\d+\s+or\s+OIML\s+R\s+\d+\s+/i, "")
      # Convert "Ref 0,2" → "Ref(0.2)", "X 0,5" → "X(0.5)" — space form with European decimal
      s = s.sub(/^(Ref|X)\s+(\d+),(\d+)/i) { "#{$1}(#{$2}.#{$3})" }
      # Convert "Ref 0.2" → "Ref(0.2)", "X 0.5" → "X(0.5)" — space form with dot decimal
      s = s.sub(/^(Ref|X)\s+(\d+(?:\.\d+)?)/i) { "#{$1}(#{$2})" }
      # Convert Ref(0,2) → Ref(0.2), X(0,5) → X(0.5) — European decimal in parens
      s = s.sub(/(Ref|X)\((\d+),(\d+)\)/i) { "#{$1}(#{$2}.#{$3})" }
      # Normalize whitespace inside parens
      s = s.sub(/(Ref|X)\(\s*(\d+(?:\.\d+)?)\s*\)/i) { "#{$1}(#{$2})" }
      # Capitalize Ref / X
      s = s.sub(/^ref\(/i, "Ref(").sub(/^x\(/i, "X(")
      s
    end

    TEST_REPORT_ROLE = {
      "type_evaluation_report"      => "type_evaluation_report",
      "test_report"                 => "test_report",
      "documentation_file"          => "documentation_file",
      "evaluation_report"           => "evaluation_report",
      "pattern_evaluation_checklist"=> "pattern_evaluation_checklist",
      "pattern_evaluation_report"   => "pattern_evaluation_report",
      # Surface forms from extraction data
      "checklist"                   => "pattern_evaluation_checklist",
      "Checklist"                   => "pattern_evaluation_checklist",
      "type_evaluation"             => "type_evaluation_report",
      "evaluation"                  => "evaluation_report",
      "documentation"               => "documentation_file",
      "pattern_evaluation"          => "pattern_evaluation_report",
      "test"                        => "test_report",
      "Test report"                 => "test_report",
      "Test Report"                 => "test_report",
    }.freeze

    # ── Helpers ───────────────────────────────────────────────────────

    def self.na_if_blank(v)
      case v
      when nil, "", [], {} then NA
      else v
      end
    end

    def self.to_str(v)
      case v
      when nil then nil
      when Integer, Float then v.to_s
      else v
      end
    end

    def self.unwrap_value(v)
      return v unless v.is_a?(Hash)
      if v.key?("value") && v.keys.size == 1
        return v["value"]
      end
      v
    end

    def self.recover_raw(hash)
      return hash unless hash.is_a?(Hash)
      v = hash["value"]
      raw = hash["_raw"]
      if (v.nil? || v == "") && raw.is_a?(Hash) && raw.key?("value") && !raw["value"].nil?
        hash = hash.dup
        hash["value"] = raw["value"]
        hash.delete("_raw")
      end
      hash
    end

    # ── Structured value ──────────────────────────────────────────────

    def self.normalize_structured_value(input, value_map: nil)
      return { "value" => NA } if input.nil? || input == ""

      unless input.is_a?(Hash)
        mapped = value_map ? (value_map[input] || input) : input
        return { "value" => normalize_scalar(mapped) }
      end

      h = recover_raw(input)
      v = h.key?("value") ? unwrap_value(h["value"]) : h

      if v.is_a?(Hash) && (v.key?("min") || v.key?("max"))
        min = v.key?("min") && !v["min"].nil? && v["min"] != "" ? normalize_scalar(v["min"]) : NA
        max = v.key?("max") && !v["max"].nil? && v["max"] != "" ? normalize_scalar(v["max"]) : NA
        out = { "value" => { "min" => min, "max" => max } }
      elsif v.is_a?(Array)
        out = { "value" => v.map { |e| normalize_scalar(e) } }
      else
        mapped = value_map ? (value_map[v] || v) : v
        out = { "value" => normalize_scalar(mapped) }
      end

      if h.key?("unit_symbol") && !h["unit_symbol"].nil? && h["unit_symbol"] != ""
        out["unit_symbol"] = h["unit_symbol"].to_s
        # Populate unit_id if missing — resolve from unit_symbol via unitsdb.
        if h.key?("unit_id") && !h["unit_id"].nil? && h["unit_id"] != ""
          out["unit_id"] = h["unit_id"].to_s
        else
          resolved = resolve_unit_id(out["unit_symbol"])
          out["unit_id"] = resolved if resolved
        end
      end
      # Carry over unit_id if explicitly present even without unit_symbol
      if h.key?("unit_id") && !h["unit_id"].nil? && h["unit_id"] != "" && !out.key?("unit_id")
        out["unit_id"] = h["unit_id"].to_s
      end
      if h.key?("footnote_markers") && h["footnote_markers"].is_a?(Array) && !h["footnote_markers"].empty?
        out["footnote_markers"] = h["footnote_markers"].compact
      end
      if h.key?("tolerance") && !h["tolerance"].nil?
        out["tolerance"] = h["tolerance"]
      end
      if h.key?("tolerance_type") && !h["tolerance_type"].nil? && h["tolerance_type"] != ""
        out["tolerance_type"] = h["tolerance_type"]
      end
      out
    end

    def self.normalize_scalar(raw)
      return NA if raw.nil? || raw == ""
      raw
    end

    # ── Unit resolution (via unitsdb gem) ─────────────────────────────

    # Load the unitsdb gem Database once at module-load time.
    # The gem provides proper Unit model objects with symbols, names,
    # root_units composition, prefix references — far richer than our
    # prior flat YAML scan.
    UNITSDB = begin
      require "unitsdb"
      db_path = ENV["UNITSDB_PATH"] || "/Users/mulgogi/src/unitsml/unitsdb"
      Unitsdb::Database.from_db(db_path)
    rescue LoadError, StandardError => e
      warn "unitsdb gem not available (#{e.message}); unit resolution will be limited" if ENV["OIMLCERT_DEBUG"]
      nil
    end

    # Build a comprehensive surface-symbol → unitsml unit_id map by walking
    # every Unit in unitsdb via the gem API. Covers all symbol variants
    # (unicode, ascii, id, html, latex, mathml).
    UNIT_SYMBOL_TO_ID = begin
      m = {}
      if UNITSDB
        UNITSDB.units.each do |u|
          uid = u.identifiers.find { |i| i.id&.start_with?("u:") }&.id
          next unless uid
          m[u.short] = uid if u.short && !m.key?(u.short)
          (u.symbols || []).each do |sym|
            [:unicode, :ascii, :id].each do |k|
              v = sym.send(k) if sym.respond_to?(k)
              if v && !v.to_s.empty? && !m.key?(v)
                m[v] = uid
              end
            end
          end
        end
      end
      m
    rescue StandardError
      {}
    end.freeze

    # Cache of locally-constructed compound units missing from unitsdb.
    # These are Unit-shaped hashes with `root_units` composition following
    # unitsdb's pattern: each factor is {power:, unit_reference:}.
    LOCAL_COMPOUND_UNITS = {
      "u:gram_per_liter" => {
        names: [{ value: "gram per liter", lang: "en" }],
        short: "gram_per_liter",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:gram" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:liter" } },
        ],
      },
      "u:milligram_per_liter" => {
        names: [{ value: "milligram per liter", lang: "en" }],
        short: "milligram_per_liter",
        root_units: [
          { power: 1, prefix_reference: { type: "unitsml", id: "p:milli" }, unit_reference: { type: "unitsml", id: "u:gram" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:liter" } },
        ],
      },
      "u:meter_per_minute" => {
        names: [{ value: "meter per minute", lang: "en" }],
        short: "meter_per_minute",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:meter" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:minute" } },
        ],
      },
      "u:standard_cubic_meter" => {
        names: [{ value: "standard cubic meter", lang: "en" }],
        short: "standard_cubic_meter",
        notes: "Gas volume at standard conditions (15°C, 101.325 kPa).",
        root_units: [
          { power: 1, unit_reference: { type: "unitsml", id: "u:cubic_meter" } },
        ],
      },
      "u:normal_cubic_meter" => {
        names: [{ value: "normal cubic meter", lang: "en" }],
        short: "normal_cubic_meter",
        notes: "Gas volume at normal conditions (0°C, 101.325 kPa).",
        root_units: [
          { power: 1, unit_reference: { type: "unitsml", id: "u:cubic_meter" } },
        ],
      },
      "u:cubic_centimeter_per_gram" => {
        names: [{ value: "cubic centimeter per gram", lang: "en" }],
        short: "cubic_centimeter_per_gram",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:cubic_centimeter" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:gram" } },
        ],
      },
      "u:kilogram_per_standard_cubic_meter" => {
        names: [{ value: "kilogram per standard cubic meter", lang: "en" }],
        short: "kilogram_per_standard_cubic_meter",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:kilogram" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:standard_cubic_meter" } },
        ],
      },
      "u:meter_per_square_millimeter" => {
        names: [{ value: "meter per square millimeter", lang: "en" }],
        short: "meter_per_square_millimeter",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:meter" } },
          { power: -2, prefix_reference: { type: "unitsml", id: "p:milli" }, unit_reference: { type: "unitsml", id: "u:meter" } },
        ],
      },
      "u:impulse_per_cubic_meter" => {
        names: [{ value: "impulse per cubic meter", lang: "en" }],
        short: "impulse_per_cubic_meter",
        notes: "OIML-specific: meter pulse constant for gas meters.",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:count" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:cubic_meter" } },
        ],
      },
      "u:impulse_per_kilometer" => {
        names: [{ value: "impulse per kilometer", lang: "en" }],
        short: "impulse_per_kilometer",
        notes: "OIML-specific: taximeter distance pulse constant.",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:count" } },
          { power: -1, prefix_reference: { type: "unitsml", id: "p:kilo" }, unit_reference: { type: "unitsml", id: "u:meter" } },
        ],
      },
      "u:impulse_per_kilowatt_hour" => {
        names: [{ value: "impulse per kilowatt hour", lang: "en" }],
        short: "impulse_per_kilowatt_hour",
        notes: "OIML-specific: electricity meter constant.",
        root_units: [
          { power: 1,  unit_reference: { type: "unitsml", id: "u:count" } },
          { power: -1, unit_reference: { type: "unitsml", id: "u:kilowatt_hour" } },
        ],
      },
    }.freeze

    # Custom OIML count units — dimensionless counters used in metrology.
    # These are pure counts (no physical dimension); they live in our local
    # extension because unitsdb doesn't model them.
    LOCAL_COUNT_UNITS = {
      "u:division"              => "count of scale divisions (R76/R51 weighing instruments)",
      "u:digit"                 => "count of display digits",
      "u:decimal_place"         => "count of decimal places",
      "u:package_per_minute"    => "R61 AGFI package throughput rate",
      "u:piece_per_minute"      => "piece throughput rate",
      "u:load_per_minute"       => "R51 load cycle rate",
      "u:package_per_hour_per_head" => "R61 multi-head filler throughput",
      "u:customary_unit"        => "R21 taximeter customary fare unit",
      "u:customary_unit_per_hour" => "R21 customary fare unit per hour",
      "u:customary_unit_per_kilometer" => "R21 customary fare unit per kilometer",
    }.freeze

    # Local overrides for OIML context where unitsdb's default mapping is wrong.
    # Example: "t" in OIML = metric tonne (1000 kg), not short ton.
    UNIT_OVERRIDES = {
      "t"       => "u:metric_ton",     # OIML "t" = tonne, not short_ton
      "°C"      => "u:degree_Celsius",
      "℃"       => "u:degree_Celsius",
      "Ω"       => "u:ohm",
      "Ω"       => "u:ohm",            # U+2126 OHM SIGN
      "ohm"     => "u:ohm",
      "Ohm"     => "u:ohm",
      "kΩ"      => "u:kiloohm",
      "MΩ"      => "u:megaohm",
      "mV/V"    => "u:millivolt_per_volt",
      "m³/h"    => "u:cubic_meter_per_hour",
      "m³/hr"   => "u:cubic_meter_per_hour",
      "m3/h"    => "u:cubic_meter_per_hour",
      "L/min"   => "u:liter_per_minute",
      "l/min"   => "u:liter_per_minute",
      "lpm"     => "u:liter_per_minute",
      "kg/m³"   => "u:kilogram_per_cubic_meter",
      "kg/m3"   => "u:kilogram_per_cubic_meter",
      "g/cm³"   => "u:gram_per_cubic_centimeter",
      "kg/min"  => "u:kilogram_per_minute",
      "kg/h"    => "u:kilogram_per_hour",
      "t/h"     => "u:metric_ton_per_hour",
      "imp/kWh" => "u:impulse_per_kilowatt_hour",
      "imp./kWh" => "u:impulse_per_kilowatt_hour",
      "imp/m³"  => "u:impulse_per_cubic_meter",
      "pulses/m³" => "u:impulse_per_cubic_meter",
      "pulses/liter" => "u:impulse_per_liter",
      "km/h"    => "u:kilometer_per_hour",
      "m/s"     => "u:meter_per_second",
      "mm/s"    => "u:millimeter_per_second",
      "%vol"    => "u:volume_percent",
      "%Mass"   => "u:mass_fraction",
      "%RO"     => "u:ratio_percent",
      "%"       => "u:percent",
      "dm³"     => "u:liter",           # 1 dm³ = 1 L exactly
      "dm3"     => "u:liter",
      "dm³/h"   => "u:liter_per_hour",
      "L/hour"  => "u:liter_per_hour",
      "Litres"  => "u:liter",
      "litres"  => "u:liter",
      "liter"   => "u:liter",
      "litre"   => "u:liter",
      "mPa·s"   => "u:millipascal_second",
      "mPa.s"   => "u:millipascal_second",
      "mPas"    => "u:millipascal_second",
      "Pa·s"    => "u:pascal_second",
      "Pa*s"    => "u:pascal_second",
      "inch"    => "u:inch",
      "in"      => "u:inch",
      "psi"     => "u:pound_force_per_square_inch",
      "PSI"     => "u:pound_force_per_square_inch",
      "Psi"     => "u:pound_force_per_square_inch",
      "dB"      => "u:decibel",
      "ppmvol"  => "u:part_per_million_volume",
      "kHz"     => "u:hertz",            # prefix-aware resolver handles, but explicit for clarity
      "MHz"     => "u:hertz",
      # Symbol variants — unitsdb has these but with different surface forms.
      # unitsdb uses middle-dot for compound symbols; cert data uses no separator.
      "kWh"     => "u:kilowatt_hour",       # unitsdb symbol: kW·h
      "Wh"      => "u:watt_hour",           # unitsdb symbol: W·h
      "kW·h"    => "u:kilowatt_hour",
      "W·h"     => "u:watt_hour",
      "km/hr"   => "u:kilometer_per_hour",  # variant of km/h
      "kmh"     => "u:kilometer_per_hour",
      # Compound units missing from unitsdb — local registration via inline composition.
      # These reference unitsml base units and document the composition.
      "m/min"   => "u:meter_per_minute",          # = u:meter / u:minute
      "L/min"   => "u:liter_per_minute",
      "l/min"   => "u:liter_per_minute",
      "lpm"     => "u:liter_per_minute",
      "mg/L"    => "u:milligram_per_liter",        # = p:milli + u:gram / u:liter
      "mg/l"    => "u:milligram_per_liter",
      "g/L"     => "u:gram_per_liter",
      "Sm³"     => "u:standard_cubic_meter",       # gas volume at STP (15°C, 1 atm)
      "Sm3"     => "u:standard_cubic_meter",
      "Nm³"     => "u:normal_cubic_meter",         # gas volume at NTP (0°C, 1 atm)
      "Nm3"     => "u:normal_cubic_meter",
      "kg/Sm³"  => "u:kilogram_per_standard_cubic_meter",
      "kg/Sm3"  => "u:kilogram_per_standard_cubic_meter",
      "cm³/g"   => "u:cubic_centimeter_per_gram",  # magnetic susceptibility
      "cm3/g"   => "u:cubic_centimeter_per_gram",
      "m/mm²"   => "u:meter_per_square_millimeter",
      "m/mm2"   => "u:meter_per_square_millimeter",
      "m³/h"    => "u:cubic_meter_per_hour",
      "m³/hr"   => "u:cubic_meter_per_hour",
      "m3/h"    => "u:cubic_meter_per_hour",
      "imp/kWh" => "u:impulse_per_kilowatt_hour",
      "imp./kWh" => "u:impulse_per_kilowatt_hour",
      "imp/m³"  => "u:impulse_per_cubic_meter",
      "impulses/m³" => "u:impulse_per_cubic_meter",
      "pulses/m³" => "u:impulse_per_cubic_meter",
      "m³/imp"  => "u:cubic_meter_per_impulse",
      "imp/km"  => "u:impulse_per_kilometer",
      "pulses/km" => "u:impulse_per_kilometer",
      "pulse/revolution" => "u:impulse_per_revolution",
      "μV/e"    => "u:microvolt_per_verification_interval",  # R76-specific
      "µV/e"    => "u:microvolt_per_verification_interval",
      "μV/div"  => "u:microvolt_per_division",
      "µV/div"  => "u:microvolt_per_division",
      "μA/div"  => "u:microampere_per_division",
      "%RH"     => "u:relative_humidity_percent",
      "%Max"    => "u:percent_of_maximum_capacity",
      "/degC"   => "u:per_degree_Celsius",          # reciprocal temperature (coeff)
      "CU/h"    => "u:customary_unit_per_hour",     # R21-specific
      "CU/km"   => "u:customary_unit_per_kilometer",
      "CU"      => "u:customary_unit",              # R21 fare totalizer
      "µV"      => "u:microvolt",                   # U+00B5 variant of μV
      "P/m3"    => "u:impulse_per_cubic_meter",     # variant of imp/m³
      "m3"      => "u:cubic_meter",                 # variant of m³
      "Bar"     => "u:bar",                         # case variant
      "bars"    => "u:bar",                         # plural variant
      # Plural forms of standard units
      "minutes" => "u:minute",                      # plural of minute (time)
      "months"  => "u:month",                       # calendar month
      "meters"  => "u:meter",                       # plural of meter (length) — context disambiguates from "count of meters"
      # Typo variants — parse the intended unit, flag with _qualifier
      "A)"      => "u:ampere",                      # stray paren typo
    }.freeze

    # Unit_symbols that CARRY MEANING but have additional qualifiers.
    # Parse them into unit_id + qualifier fields rather than dropping.
    # The qualifier text is preserved in `_qualifier` for round-trip fidelity.
    QUALIFIED_UNIT_PATTERNS = {
      # Voltage with current_type / waveform qualifiers
      "V (optional)" => {
        unit_id: "u:volt",
        _qualifier: "optional",
      },
      "V AC square wave" => {
        unit_id: "u:volt",
        current_type: "AC",
        _qualifier: "square_wave",
      },
      # Speed with conditional applicability
      "m/min for greater loads" => {
        unit_id: "u:meter_per_minute",
        _qualifier: "for_greater_loads",
      },
    }.freeze

    # Bare degree symbol — needs context to disambiguate:
    # - If attribute is temperature-related → u:degree_Celsius
    # - If attribute is angle-related → u:degree (plane angle)
    # - Otherwise → suspect
    TEMPERATURE_ATTRS = %w[
      temperature ambient_temperature product_temperature liquid_temperature
      temperature_range ambient_temperature_range product_temperature_range
      temperature_coefficient thermal
    ].freeze
    ANGLE_ATTRS = %w[angle inclination tilt direction].freeze

    def self.resolve_bare_degree(attribute_name)
      return nil unless attribute_name
      attr = attribute_name.to_s.downcase
      if TEMPERATURE_ATTRS.any? { |t| attr.include?(t) }
        "u:degree_Celsius"
      elsif ANGLE_ATTRS.any? { |t| attr.include?(t) }
        "u:degree"
      else
        nil
      end
    end

    # Unit_symbols that are NOT real units — text leaked from GLM extraction.
    # These are kept as-is but flagged with a _note so reviewers can decide.
    # The unit_symbol is preserved; a _note is added so the schema can route
    # these to a review queue without losing the original data.
    SUSPECT_UNIT_SYMBOLS = {
      "firmware"                          => "firmware text leaked into unit field",
      "wire"                              => "material spec leaked into unit field",
      "wire configuration)"               => "truncated text leaked into unit field",
      "wire and screen"                   => "cable spec leaked into unit field",
      "for the indicator"                 => "descriptive text leaked into unit field",
      "screened"                          => "cable type text leaked into unit field",
      "or higher"                         => "conditional text leaked into unit field",
      "or more pairs of load receptors"   => "conditional text leaked into unit field",
      "or more bending plates"            => "conditional text leaked into unit field",
      "PM weighing pads"                  => "manufacturer product name leaked into unit field",
      "BPR weighing pads"                 => "manufacturer product name leaked into unit field",
      "Vertical (diagnostics)"            => "orientation text leaked into unit field",
      "xEthernet"                         => "protocol name leaked into unit field",
      "e for class Y(a)"                  => "accuracy class text leaked into unit field",
      "FF"                                => "letter leaked into unit field (likely checksum)",
      "AE"                                => "letter leaked into unit field (likely identifier)",
      "Z"                                 => "letter leaked into unit field (likely identifier)",
      "xy"                                => "placeholder text in unit field",
      "x"                                 => "placeholder text in unit field",
      "xxxxx"                             => "placeholder text in unit field",
    }.freeze

    # Unit_symbols that represent OIML/metrology-specific COUNTS or RATES.
    # These are registered as custom local units (not in unitsdb) with
    # semantic meaning. unit_id starts with "u:" but lives in our local
    # extension (schema/_units_local.yaml).
    # Note: minutes/months/meters are NOT here — those are standard time/length
    # units with plural surface forms (handled in UNIT_OVERRIDES).
    CUSTOM_COUNT_UNITS = {
      "divisions"                          => "u:division",                # count of scale divisions (R76/R51)
      "digits"                             => "u:digit",                   # count of display digits
      "decimals"                           => "u:decimal_place",           # count of decimal places
      "decimals)"                          => "u:decimal_place",           # variant with stray paren
      "packages per minute"                => "u:package_per_minute",      # R61 AGFI throughput
      "packages/min"                       => "u:package_per_minute",
      "packs/min"                          => "u:package_per_minute",
      "pieces/min"                         => "u:piece_per_minute",
      "packages per hour per filling head" => "u:package_per_hour_per_head", # R61 multi-head
      "loads/min"                          => "u:load_per_minute",         # R51 load cycle rate
    }.freeze

    # Unit_symbols that explicitly mean "no unit applies". Delete the field —
    # absence is the canonical representation of "no unit".
    NO_UNIT_SYMBOLS = [
      "-", "",
    ].freeze

    # Surface-form qualifiers that should be stripped from unit_symbol
    # before lookup. Returns [base_symbol, qualifier_pair_or_nil].
    def self.strip_unit_qualifiers(symbol)
      s = symbol.to_s.strip
      # Strip whitespace
      s = s.gsub(/\s+/, "")
      # Pressure reference: bar(g), bar(a), barg, bara
      if s =~ /^(.*)((?:\(g\)|\(a\)|\(d\)|g|a))$/i && %w[bar pa kpa mpa psi].include?(Regexp.last_match(1).downcase)
        base = Regexp.last_match(1)
        qual = Regexp.last_match(2).downcase.delete("()")
        ref = { "g" => "gauge", "a" => "absolute", "d" => "differential" }[qual]
        return [base, [:reference, ref]] if ref
      end
      # Current type: VAC, VDC, AAC, ADC
      if s =~ /^(V|A|W)(AC|DC|AC\/DC)$/i
        base = Regexp.last_match(1).upcase
        ct = Regexp.last_match(2).upcase.gsub("/", "_")
        return [base, [:current_type, ct]]
      end
      [s, nil]
    end

    def self.resolve_unit_id(symbol)
      return nil if symbol.nil? || symbol.to_s.empty?
      s = symbol.to_s.strip
      # Check overrides first
      return UNIT_OVERRIDES[s] if UNIT_OVERRIDES.key?(s)
      # Strip qualifiers and try again
      base, = strip_unit_qualifiers(s)
      return UNIT_OVERRIDES[base] if UNIT_OVERRIDES.key?(base)
      return UNIT_SYMBOL_TO_ID[base] if UNIT_SYMBOL_TO_ID.key?(base)
      # Try the original symbol
      return UNIT_SYMBOL_TO_ID[s] if UNIT_SYMBOL_TO_ID.key?(s)
      # Try stripping an SI prefix (m, k, M, μ, c, d, etc.) and lookup base unit.
      # Order: longer prefixes first to avoid ambiguity (da before d).
      PREFIX_BY_SYMBOL.each do |sym, pid|
        next if sym.length >= s.length
        next unless s.start_with?(sym)
        remainder = s[sym.length..]
        # Don't strip if remainder is too short or doesn't look like a base unit
        next if remainder.empty? || remainder.length > 10
        base_id = UNIT_SYMBOL_TO_ID[remainder] || UNIT_OVERRIDES[remainder]
        return base_id if base_id # prefix resolution succeeded
      end
      nil
    end

    # Map of single/multi-char prefix surface forms to prefix IDs,
    # ordered longest-first so "da" matches before "d".
    PREFIX_BY_SYMBOL = begin
      db = ENV["UNITSDB_PATH"] || "/Users/mulgogi/src/unitsml/unitsdb"
      prefixes = YAML.load_file("#{db}/prefixes.yaml")["prefixes"]
      m = {}
      prefixes.each do |p|
        pid = p["identifiers"]&.find { |i| i["type"] == "unitsml" }&.dig("id")
        next unless pid
        next if p["short"] == "none" # skip the no-prefix entry
        (p["symbols"] || []).each do |sym|
          %w[unicode ascii].each do |k|
            v = sym[k]
            next unless v && v != "1"
            m[v] = pid unless m.key?(v)
          end
        end
      end
      # Sort by length descending so "da" wins over "d"
      m.to_a.sort_by { |k, _| -k.length }.to_h
    rescue StandardError
      {}
    end.freeze

    # ── Top-level cert normalization ──────────────────────────────────

    # normalize_cert accepts an optional recommendation_id: ("R60", "R61", ...)
    # to disambiguate R-specific enums (e.g. R60 humidity_class is CH/NH/SH;
    # R61/other Rs use D 11 H1/H2/H3).
    def self.normalize_cert(cert, recommendation_id: nil)
      return cert unless cert.is_a?(Hash)
      # Priority: explicit parameter > _meta.recommendation > recommendation.id
      # The _meta field is more reliable than recommendation.id (which may have
      # extraction errors like assigning the wrong R id).
      r_id = recommendation_id || detect_r_from_meta(cert) || cert.dig("recommendation", "id")
      out = cert.dup

      out["certificate"]         = normalize_certificate(out["certificate"])         if out["certificate"]
      # Pass the certificate's oiml_issuer_id to the IA normalizer so it
      # can canonicalize the name even when the IA hash lacks the ID field.
      if out["issuing_authority"]
        cert_issuer_id = out["certificate"] && out["certificate"]["oiml_issuer_id"]
        out["issuing_authority"] = normalize_issuing_authority(out["issuing_authority"], cert_issuer_id: cert_issuer_id)
      end
      %w[applicants manufacturers].each do |k|
        if out.key?(k)
          normalized = normalize_party_list(out[k])
          # Remove empty party lists so schema validation (minItems: 1) doesn't fail.
          # These fields are optional; an empty list means extraction found nothing.
          if normalized.empty?
            out.delete(k)
          else
            out[k] = normalized
          end
        end
      end
      # Fix the "The applicant" extraction artifact: when a manufacturer
      # entry has name="The applicant" (or similar GLM literal), copy the
      # name from the first applicant. The applicant list is authoritative
      # for the legal manufacturer identity in this case.
      if out["manufacturers"] && out["applicants"]
        first_applicant_name = out["applicants"].is_a?(Array) && out["applicants"].first &&
                               out["applicants"].first["name"]
        if first_applicant_name
          out["manufacturers"].each do |m|
            next unless m.is_a?(Hash)
            current = m["name"].to_s
            if current.match?(/\Athe\s+(applicant|manufacturer)\s*\z/i)
              m["name"] = first_applicant_name
            end
          end
        end
      end
      out["certified_type"]      = normalize_certified_type(out["certified_type"], r_id)   if out["certified_type"]
      out["characteristics"]     = normalize_characteristics(out["characteristics"], r_id) if out["characteristics"]
      out["recommendation"]      = normalize_recommendation(out["recommendation"], r_id)   if out["recommendation"]
      out["test_reports"]        = normalize_test_reports(out["test_reports"])       if out["test_reports"]
      out["revision_history"]    = normalize_revision_history(out["revision_history"]) if out["revision_history"]
      out["components"]          = normalize_components(out["components"])           if out["components"]
      out["matrix_tables"]       = normalize_matrix_tables(out["matrix_tables"])     if out["matrix_tables"]
      out["footnotes"]           = normalize_footnotes(out["footnotes"])             if out["footnotes"]
      out["model_family"]        = normalize_model_family(out["model_family"])       if out["model_family"]
      # Final sweep: walk the entire cert and resolve any remaining unit_symbol
      # fields that live inside nested structures GLM created (e.g. a value
      # field that's actually a hash with its own unit_symbol/values).
      resolve_units_recursive(out)
      out
    end

    # Detect R from _meta.recommendation or filename hint in _meta.source_pdf
    def self.detect_r_from_meta(cert)
      m = cert["_meta"]
      return nil unless m.is_a?(Hash)
      m["recommendation"] || (m["source_pdf"] && m["source_pdf"][/\bR(\d{2,3})\b/i, 1] && "R#{$1}")
    end

    # ── Per-field normalizers ─────────────────────────────────────────

    def self.normalize_certificate(c)
      out = c.dup
      # Strip fields not in the Certificate schema (edition belongs on recommendation)
      %w[edition].each { |k| out.delete(k) }
      if out.key?("project_number")
        if out["project_number"].nil? || out["project_number"] == ""
          out.delete("project_number")
        else
          out["project_number"] = to_str(out["project_number"])
        end
      end
      # If project_number duplicates certificate.number, the extractor confused
      # the two fields. Drop project_number entirely — it's not a real value.
      if out.key?("project_number") && out.key?("number") &&
         out["project_number"].to_s == out["number"].to_s
        out.delete("project_number")
      end
      %w[page_total member_state date_issued].each do |f|
        if out.key?(f) && (out[f].nil? || out[f] == "")
          out.delete(f)
        end
      end
      # Canonicalize member_state to the official short name.
      if out.key?("member_state")
        canonical = canonical_member_state(out["member_state"])
        out["member_state"] = canonical if canonical
      end
      # Ensure date_issued is a string (some extraction data has integer year)
      if out.key?("date_issued") && !out["date_issued"].is_a?(String)
        out["date_issued"] = if out["date_issued"].respond_to?(:strftime)
                               out["date_issued"].strftime("%Y-%m-%d")
                             else
                               out["date_issued"].to_s
                             end
      end
      # Coerce scheme to string if present; default to "A" if nil
      if out.key?("scheme")
        out["scheme"] = if out["scheme"].nil? || out["scheme"] == ""
                          "A"
                        else
                          out["scheme"].to_s
                        end
      end
      out
    end

    def self.normalize_issuing_authority(ia, cert_issuer_id: nil)
      out = ia.dup
      # Ensure required `name` field is present
      if !out.key?("name") || out["name"].nil? || out["name"] == ""
        out["name"] = NA
      end
      # Canonicalize name against the cert's issuer ID when available.
      # The ID is on either the issuing_authority hash or the certificate.
      issuer_id = out["oiml_issuer_id"] || cert_issuer_id
      canonical = canonical_issuing_authority(out["name"], issuer_id: issuer_id)
      out["name"] = canonical if canonical
      %w[person_responsible person_title phone fax email website oiml_issuer_id].each do |f|
        if out.key?(f)
          val = out[f]
          out[f] = (val.nil? || val == "") ? NA : val.to_s
        end
      end
      # Canonicalize email, website, phone, fax.
      out["email"]   = canonical_email(out["email"])      if out.key?("email")
      out["website"] = canonical_website(out["website"])  if out.key?("website")
      out["phone"]   = canonical_phone(out["phone"])      if out.key?("phone")
      out["fax"]     = canonical_phone(out["fax"])        if out.key?("fax")
      # Strip stray whitespace from person fields.
      %w[person_responsible person_title].each do |f|
        out[f] = strip_string(out[f]) if out.key?(f) && out[f].is_a?(String) && out[f] != NA
      end
      if out.key?("address_lines")
        if out["address_lines"].nil? || out["address_lines"] == []
          out.delete("address_lines")
        else
          out["address_lines"] = out["address_lines"].map(&:to_s)
        end
      end
      out
    end

    def self.normalize_party_list(pl)
      return [] if pl.nil? || pl == []
      pl.map { |p| normalize_party(p) }.compact
    end

    # Heuristic extraction-error fixes for party names. These run on
    # both applicants and manufacturers. Returns the cleaned name.
    def self.canonical_party_name(name)
      return nil if name.nil?
      s = name.to_s.strip
      return nil if s.empty?
      # GLM artifact: literal text "The applicant" / "The manufacturer"
      # leaked into the name field. Caller resolves via applicant list.
      return nil if s.match?(/\Athe\s+(applicant|manufacturer)\s*\z/i)
      s
    end

    def self.normalize_party(p)
      return nil if p.nil? || p == {}
      out = p.dup
      name = p["name"]
      out["name"] = (name.nil? || name == "") ? NA : strip_string(name.to_s)
      # Canonicalize company-name formatting (title-case all-caps names
      # with legal suffixes, normalize spacing/punctuation).
      if out["name"] != NA
        canonical = canonical_company_name(out["name"])
        out["name"] = canonical if canonical
      end
      if p.key?("address_lines") && !p["address_lines"].nil? && p["address_lines"] != []
        out["address_lines"] = p["address_lines"].map(&:to_s)
      else
        out.delete("address_lines")
      end
      out
    end

    def self.normalize_certified_type(ct, r_id = nil)
      out = ct.dup
      if out.key?("module_designation")
        v = out["module_designation"]
        # R61 uses InstrumentType; R60 uses LoadCellCharacterization
        r61_map    = R61_INSTRUMENT_TYPE
        r60_map    = LOAD_CELL_CHARACTERIZATION
        out["module_designation"] = if v.is_a?(Hash)
                                      normalize_structured_value(v, value_map: r60_map)
                                    else
                                      r61_map[v] || r61_map[v.to_s] ||
                                        r60_map[v] || r60_map[v.to_s] ||
                                        v
                                    end
      end
      if out.key?("description")
        if out["description"].nil? || out["description"] == ""
          out.delete("description")
        else
          out["description"] = strip_string(out["description"].to_s)
        end
      end
      if out.key?("type_designations") && out["type_designations"].is_a?(Array)
        out["type_designations"] = out["type_designations"].map(&:to_s)
      end
      # Ensure required fields category and type_designations are present
      if !out.key?("category") || out["category"].nil? || out["category"] == ""
        out["category"] = NA
      end
      if !out.key?("type_designations") || !out["type_designations"].is_a?(Array) || out["type_designations"].empty?
        out["type_designations"] = [NA]
      end
      if out.key?("category") && !out["category"].nil?
        out["category"] = out["category"].to_s
      end
      out
    end

    def self.normalize_characteristics(ch, r_id = nil)
      out = ch.dup
      %w[type_level model_level config_level].each do |layer|
        next unless out[layer]
        out[layer] = normalize_characteristics_layer(out[layer], r_id)
      end
      # software_identification is not a StructuredValue — normalize it specially.
      # Common extraction shape: {value: <integer>, unit_symbol: "..."} — the
      # value may be a number (version count, etc.) that must be coerced to string.
      if out["type_level"].is_a?(Hash) && out["type_level"].key?("software_identification")
        out["type_level"]["software_identification"] = normalize_software_identification(out["type_level"]["software_identification"])
      end
      # config_level entries: rename `model` → `condition` in values[] (many
      # extraction outputs use `model` as the key, but schemas require `condition`).
      if out["config_level"].is_a?(Array)
        out["config_level"] = out["config_level"].map { |e| normalize_config_level_entry(e) }
      end
      out
    end

    def self.normalize_characteristics_layer(layer, r_id = nil)
      case layer
      when Hash
        result = {}
        layer.each do |k, v|
          next if v.nil? || v == {}
          # Accuracy class tokens: normalize European decimal Ref(0,2) → Ref(0.2)
          # Also wrap bare decimals "0.5" → "X(0.5)" (operational class) — but ONLY for R61
          if ["accuracy_class", "reference_accuracy_class", "reference_class"].include?(k.to_s)
            result[k] = normalize_structured_value(v, value_map: nil)
            if result[k].is_a?(Hash) && result[k]["value"].is_a?(String)
              result[k]["value"] = normalize_accuracy_class_value(result[k]["value"], k.to_s, r_id)
            elsif result[k].is_a?(Hash) && result[k]["value"].is_a?(Array)
              result[k]["value"] = result[k]["value"].map { |x| normalize_accuracy_class_value(x, k.to_s, r_id) }
            end
          elsif k.to_s == "method_of_operation"
            # Split comma-separated multi-method strings into array of canonical tokens
            result[k] = normalize_method_of_operation(v)
          elsif k.to_s == "humidity_class"
            # R60 humidity_class is CH/NH/SH; other Rs use D 11 H1/H2/H3
            map = (r_id == "R60") ? HUMIDITY_MARKING : CLIMATIC_CLASS
            result[k] = normalize_structured_value(v, value_map: map)
          else
            result[k] = normalize_structured_value(v, value_map: map_for_label(k))
          end
        end
        result
      when Array
        layer.map { |entry| normalize_model_level_entry(entry) }.compact
      else
        layer
      end
    end

    # Normalize an accuracy class value:
    # - "Ref(0,2)" → "Ref(0.2)" (European decimal) — universal
    # - For R61 only: bare "0.5" → "X(0.5)" (operational) or "Ref(0.5)" (reference)
    # - For non-R61: unwrap "X(1)" → "1" (undo the previous over-eager wrapping)
    # - For R117: fix extraction errors "5" → "0.5", "15" → "1.5"
    def self.normalize_accuracy_class_value(raw, attr_name, r_id = nil)
      return NA if raw.nil? || raw.to_s.empty?
      s = normalize_ref_x_token(raw)
      # For non-R61, unwrap X(num) back to bare decimal (undo prior corruption)
      if r_id != "R61" && s =~ /^X\((\d+(?:\.\d+)?)\)$/
        s = $1
      end
      return s if s =~ /^(Ref|X)\(/
      # R117-specific extraction error fixes
      if r_id == "R117"
        s = case s
            when "5" then "0.5"
            when "15" then "1.5"
            else s
            end
      end
      # Bare decimal — wrap only for R61
      if r_id == "R61" && s =~ /^\d+(\.\d+)?$/
        prefix = attr_name =~ /ref/ ? "Ref" : "X"
        s = "#{prefix}(#{s})"
      end
      s
    end

    # Normalize method_of_operation:
    # - Comma/semicolon/" or "/" combined with "-separated string → array of canonical tokens
    # - Single value → canonical token
    def self.normalize_method_of_operation(v)
      return { "value" => NA } if v.nil? || v == ""
      unless v.is_a?(Hash)
        return { "value" => (R61_METHOD_OF_OPERATION[v] || v) }
      end
      h = recover_raw(v)
      val = h.key?("value") ? unwrap_value(h["value"]) : h
      if val.is_a?(String) && (val.include?(",") || val =~ /\s+or\s+/i || val =~ /\s+combined\s+with\s+/i)
        # Split on commas, semicolons, " or ", " combined with "
        tokens = val.split(/[,;]|\s+or\s+|\s+combined\s+with\s+/i).map(&:strip).map do |t|
          R61_METHOD_OF_OPERATION[t] || t
        end.uniq
        out = { "value" => tokens }
      else
        mapped = val.is_a?(Array) ? val.map { |x| R61_METHOD_OF_OPERATION[x] || x } : (R61_METHOD_OF_OPERATION[val] || val)
        out = { "value" => mapped }
      end
      if h.key?("footnote_markers") && h["footnote_markers"].is_a?(Array) && !h["footnote_markers"].empty?
        out["footnote_markers"] = h["footnote_markers"].compact
      end
      out
    end

    def self.normalize_model_level_entry(entry)
      return nil unless entry.is_a?(Hash)
      out = entry.dup
      out["attribute"] = to_str(out["attribute"]) if out["attribute"]
      # Resolve unit_symbol → unit_id at the entry level. If unit_symbol is
      # empty/nil, DELETE the key entirely (don't keep empty `unit_symbol:`).
      if out.key?("unit_symbol")
        us = out["unit_symbol"]
        if us.nil? || us.to_s.empty?
          out.delete("unit_symbol")
        else
          out["unit_symbol"] = us.to_s
          if !out.key?("unit_id") || out["unit_id"].nil? || out["unit_id"] == ""
            resolved = resolve_unit_id(out["unit_symbol"])
            out["unit_id"] = resolved if resolved
          end
        end
      end
      if out["values"].is_a?(Array)
        out["values"] = out["values"].map do |v|
          next { "model" => NA, "value" => NA } if v.nil?
          if v.is_a?(Hash)
            model = (v["model"].nil? || v["model"] == "") ? NA : v["model"].to_s
            value = normalize_structured_value(v["value"], value_map: map_for_label(out["attribute"]))
            entry_out = { "model" => model, "value" => value["value"] }
            if v["footnote_markers"].is_a?(Array) && !v["footnote_markers"].empty?
              entry_out["footnote_markers"] = v["footnote_markers"].compact
            end
            entry_out
          else
            { "model" => NA, "value" => normalize_scalar(v) }
          end
        end
      end
      out
    end

    # Normalize a config_level entry. The key difference from model_level is
    # that config_level values use `condition` as the discriminator key, but
    # extraction data often emits `model` instead. Rename model → condition.
    def self.normalize_config_level_entry(entry)
      return nil unless entry.is_a?(Hash)
      out = entry.dup
      out["attribute"] = to_str(out["attribute"]) if out["attribute"]
      # Ensure axis is present and a string (some extraction data omits it
      # or has null/integer)
      if !out.key?("axis") || out["axis"].nil?
        out["axis"] = NA
      elsif !out["axis"].is_a?(String)
        out["axis"] = out["axis"].to_s
      end
      if out["values"].is_a?(Array)
        out["values"] = out["values"].map do |v|
          next nil if v.nil?
          next { "condition" => NA, "value" => NA } unless v.is_a?(Hash)

          v_out = v.dup
          # Rename model → condition (config_level uses condition as discriminator)
          if v_out.key?("model") && !v_out.key?("condition")
            v_out["condition"] = v_out.delete("model")
          end
          # Ensure condition is a string
          cond = v_out["condition"]
          v_out["condition"] = (cond.nil? || cond == "") ? NA : cond.to_s
          # Normalize value through structured value path
          v_out["value"] = normalize_structured_value(v_out["value"], value_map: map_for_label(out["attribute"]))["value"]
          v_out
        end.compact
      end
      out
    end

    # Normalize software_identification. Extraction data produces shapes like
    # {value: 2, unit_symbol: "xxxxx"} where value is an integer, or multi-line
    # string values that should be parsed into the structured form. Coerce
    # non-string/non-hash/non-array values to string for schema compliance.
    def self.normalize_software_identification(si)
      # Multi-line string → parse into structured object/array form
      return parse_software_identification(si) if si.is_a?(String) && (si.include?("\n") || si =~ /\A\s*\-?\s*(?:version|checksum|board)/i)

      return si unless si.is_a?(Hash)
      out = si.dup
      if out.key?("value") && !out["value"].nil?
        v = out["value"]
        # Multi-line string inside StructuredValue value: parse + replace
        if v.is_a?(String) && (v.include?("\n") || v =~ /\A\s*\-?\s*(?:version|checksum|board)/i)
          out["value"] = parse_software_identification(v)
        elsif v.is_a?(Hash) && v["version_number"].is_a?(String) && v["version_number"] =~ /Checksum/i
          # Repair: a prior buggy parse concatenated checksum into version_number.
          # Re-parse the concatenation.
          combined = "Version: #{v['version_number']}"
          combined += " Checksum: #{v['checksum']}" if v["checksum"]
          out["value"] = parse_software_identification(combined)
        elsif v.is_a?(Integer) || v.is_a?(Float) || v.is_a?(TrueClass) || v.is_a?(FalseClass)
          # Coerce bare integers/floats/booleans to strings
          out["value"] = v.to_s
        end
      end
      out
    end

    def self.normalize_recommendation(r, r_id = nil)
      out = r.dup
      # Fix recommendation.id if it doesn't match the detected R from _meta.
      # Extraction sometimes assigns the wrong R id (e.g. R76 for an R51 cert).
      if r_id && out.key?("id") && out["id"] !~ /^#{Regexp.escape(r_id)}(-|$)/
        out["id"] = r_id
      end
      if out.key?("accuracy_classes") && out["accuracy_classes"].is_a?(Array)
        out["accuracy_classes"] = out["accuracy_classes"].map do |a|
          if r_id == "R61"
            normalize_accuracy_class_value(a, "accuracy_class", r_id)
          else
            # Unwrap X(num) → bare decimal for non-R61 (undo prior corruption)
            unwrapped = a.to_s
            if unwrapped =~ /^X\((\d+(?:\.\d+)?)\)$/
              unwrapped = $1
            end
            # R117-specific: extraction errors produce "5" (should be "0.5")
            # and "15" (should be "1.5"). Fix these.
            if r_id == "R117"
              unwrapped = case unwrapped
                          when "5" then "0.5"
                          when "15" then "1.5"
                          else unwrapped
                          end
            end
            unwrapped
          end
        end.uniq.map { |v| to_str(v) }
      end
      if out.key?("amendment") && (out["amendment"].nil? || out["amendment"] == "")
        out.delete("amendment")
      end
      out
    end

    def self.normalize_test_reports(trs)
      return [] if trs.nil? || trs == []
      trs.map { |tr| normalize_test_report(tr) }.compact
    end

    def self.normalize_test_report(tr)
      return nil if tr.nil? || tr == {}
      out = tr.dup
      # Strip provenance markers that are not part of the schema
      %w[_note _raw _decomposed _extracted_from].each { |k| out.delete(k) }
      out["id"] = to_str(out["id"]) || NA
      if out.key?("date")
        d = out["date"]
        out["date"] = if d.nil? || d == ""
                        NA
                      elsif d.respond_to?(:strftime)
                        d.strftime("%Y-%m-%d")
                      else
                        d.to_s
                      end
      else
        out["date"] = NA
      end
      if out.key?("pages")
        p = out["pages"]
        out["pages"] = (p.nil? || p == "") ? 1 : p.to_i
      else
        out["pages"] = 1
      end
      if out.key?("role") && !out["role"].nil? && out["role"] != ""
        out["role"] = TEST_REPORT_ROLE[out["role"]] || out["role"].to_s
      else
        out["role"] = "test_report"
      end
      out
    end

    def self.normalize_revision_history(rh)
      return [] if rh.nil? || rh == []
      rh.map { |e| normalize_revision_entry(e) }.compact
    end

    def self.normalize_revision_entry(e)
      return nil unless e.is_a?(Hash)
      out = e.dup
      out["revision"] = (out["revision"].nil? || out["revision"] == "") ? NA : out["revision"].to_s
      d = out["date"]
      out["date"] = if d.nil? || d == ""
                      NA
                    elsif d.respond_to?(:strftime)
                      d.strftime("%Y-%m-%d")
                    else
                      d.to_s
                    end
      out["changes"] = (out["changes"].nil? || out["changes"] == "") ? NA : strip_string(out["changes"].to_s)
      out
    end

    def self.normalize_components(comps)
      return [] if comps.nil? || comps == []
      comps.map { |c| normalize_component(c) }.compact
    end

    def self.normalize_component(c)
      return nil unless c.is_a?(Hash)
      out = c.dup
      out["role"] = (out["role"].nil? || out["role"] == "") ? NA : out["role"].to_s
      if out.key?("alternatives")
        val = out["alternatives"]
        if val.nil? || val == "" || !["OR", "AND"].include?(val)
          out.delete("alternatives")
        end
      end
      if out["characteristics"].is_a?(Hash)
        new_ch = {}
        out["characteristics"].each do |k, v|
          next if v.nil? || v == {}
          new_ch[k] = normalize_structured_value(v, value_map: map_for_label(k))
        end
        out["characteristics"] = new_ch
      end
      if out["type_designations"].is_a?(Array)
        out["type_designations"] = out["type_designations"].map(&:to_s)
      end
      out
    end

    def self.normalize_matrix_tables(mt)
      return [] if mt.nil? || mt == []
      mt.map do |t|
        next nil unless t.is_a?(Hash)
        out = t.dup
        out["name"] = (out["name"].nil? || out["name"] == "") ? NA : out["name"].to_s
        out.delete("description") if out["description"].nil? || out["description"] == ""
        # Resolve unit symbols in column_units and row cells
        if out["column_units"].is_a?(Array)
          out["column_units"] = out["column_units"].map do |cu|
            next cu if cu.nil? || cu.to_s.empty?
            cu.to_s
          end
        end
        if out["rows"].is_a?(Array)
          out["rows"] = out["rows"].map do |row|
            next row unless row.is_a?(Hash)
            row.each_with_object({}) do |(k, v), h|
              h[k] = normalize_structured_value(v)
            end
          end
        end
        out
      end.compact
    end

    def self.normalize_footnotes(fn)
      return [] if fn.nil? || fn == []
      fn.map do |f|
        next nil unless f.is_a?(Hash)
        out = f.dup
        out["marker"] = (out["marker"].nil? || out["marker"] == "") ? NA : strip_string(out["marker"].to_s)
        out["text"]   = (out["text"].nil?   || out["text"] == "")   ? NA : strip_string(out["text"].to_s)
        out
      end.compact
    end

    def self.map_for_label(label)
      return nil unless label
      case label.to_s
      when "module_designation", "characterization", "characterization_of_load_cell_capabilities"
        LOAD_CELL_CHARACTERIZATION      when "humidity_class"
        HUMIDITY_MARKING
      when "climatic_environment_class", "environmental_classes"
        CLIMATIC_CLASS
      when "mechanical_environment_class"
        MECHANICAL_CLASS
      when "electromagnetic_environment_class"
        EM_CLASS
      when "current_type", "power_supply_type"
        CURRENT_TYPE
      when "method_of_operation"
        R61_METHOD_OF_OPERATION
      else
        nil
      end
    end

    # Recursive unit-symbol resolver. Walks every hash/array in the cert and:
    # 1. Resolves unit_symbol → unit_id via unitsdb lookup + prefix composition
    # 2. Handles qualified units (V AC square wave, m/min for greater loads)
    # 3. Maps custom OIML count units (divisions, digits, packages/min) to
    #    locally-registered unit_ids
    # 4. Drops "no unit" sentinels (`-`, empty) — absence is canonical
    # 5. Flags suspected extraction errors with _note field (keeps the data)
    # `attribute` is the parent attribute name (if known) for context-based
    # disambiguation (e.g. bare `°` means temperature vs angle).
    def self.resolve_units_recursive(obj, attribute: nil)
      case obj
      when Hash
        # Track the attribute name from common keys
        attr_name = obj["attribute"] || attribute

        if obj.key?("unit_symbol")
          us = obj["unit_symbol"]
          us_str = us ? us.to_s : ""

          if us.nil? || us_str.empty? || NO_UNIT_SYMBOLS.include?(us_str)
            # Explicitly "no unit" — absence is canonical
            obj.delete("unit_symbol")

          elsif QUALIFIED_UNIT_PATTERNS.key?(us_str)
            # Parse meaningful qualified units (V AC square wave, etc.)
            pat = QUALIFIED_UNIT_PATTERNS[us_str]
            obj["unit_symbol"] = us_str
            obj["unit_id"] = pat[:unit_id]
            obj["_qualifier"] = pat[:_qualifier] if pat[:_qualifier]
            obj["current_type"] = pat[:current_type] if pat[:current_type]

          elsif us_str == "°"
            # Bare degree — disambiguate by attribute context
            resolved = resolve_bare_degree(attr_name)
            if resolved
              obj["unit_symbol"] = us_str
              obj["unit_id"] = resolved
            else
              obj["unit_symbol"] = us_str
              obj["_note"] = "bare degree symbol — context unknown (likely angle or temperature)"
            end

          elsif CUSTOM_COUNT_UNITS.key?(us_str)
            # OIML-specific count unit — register as custom local unit
            obj["unit_symbol"] = us_str
            obj["unit_id"] = CUSTOM_COUNT_UNITS[us_str]
            obj["_unit_kind"] = "custom_count"

          elsif SUSPECT_UNIT_SYMBOLS.key?(us_str)
            # Likely extraction error — keep the value but flag for review
            obj["unit_symbol"] = us_str
            obj["_note"] = SUSPECT_UNIT_SYMBOLS[us_str]

          elsif !obj.key?("unit_id") || obj["unit_id"].nil? || obj["unit_id"] == ""
            # Try unitsdb resolution
            resolved = resolve_unit_id(us)
            obj["unit_id"] = resolved if resolved
          end
        end

        # Recurse with attribute context where available
        obj.each do |k, v|
          next if k == "unit_symbol" # already handled
          child_attr = (v.is_a?(Hash) && v["attribute"]) || attr_name
          resolve_units_recursive(v, attribute: child_attr)
        end
      when Array
        obj.each { |v| resolve_units_recursive(v, attribute: attribute) }
      end
    end

    # Normalize model_family: resolve unit_symbols in model attributes.
    def self.normalize_model_family(mf)
      return mf unless mf.is_a?(Hash)
      out = mf.dup
      if out["models"].is_a?(Array)
        out["models"] = out["models"].map do |m|
          next m unless m.is_a?(Hash)
          m_out = m.dup
          if m_out["attributes"].is_a?(Hash)
            m_out["attributes"] = m_out["attributes"].each_with_object({}) do |(k, v), h|
              h[k] = normalize_structured_value(v)
            end
          end
          m_out
        end
      end
      out
    end
  end
end
