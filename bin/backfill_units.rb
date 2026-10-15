#!/usr/bin/env ruby
# frozen_string_literal: true

# Deterministic unit_id backfill: resolve unit_symbol against the unitsdb
# gem's official tables (the data layer unitsml-ruby wraps — gem-bundled,
# versioned data, no sibling-checkout path), the frozen resolver's alias
# table, the local compounds, the local counts, and — for prefixed forms
# (mV, µV, dm³, mPa·s) — composition at lookup time: SI prefix symbol + base
# symbol, with the prefix carried on the record's own Unit.prefix field.
# OIML count conventions (divisions, digits, DN) get _unit_kind per
# _core.yaml. No models, no pre-enumeration.
#
# unit_symbol is canonicalized to unitsml ascii syntax on every visit:
#   sign variants and unit words (µ μ -> u, Ω -> Ohm, ℓ -> l)
#   superscript digits (³²⁻¹ -> ^3 ^2 ^-1)
#   multiplication (· × -> *)
#   degree (° -> deg)
#   period between letters, not single-uppercase abbreviation (mPa.s -> mPa*s,
#     F.S stays F.S)
#   ascii digit after a letter, not OIML scale interval/division (m3 -> m^3,
#     dm3 -> dm^3, e1 stays e1)
# The document-true transcription lives in ocr_md; the structured tier
# carries the machine-parseable surface here. The resolver's base_map is
# keyed by both ascii and unicode symbols, so lookup works against the
# canonicalized form.

require "yaml"
require "json"
require "set"
require "unitsdb"

REPO = File.expand_path("..", __dir__)

# Sign-variant folding: visually identical code points that Unicode keeps
# distinct (OHM SIGN vs GREEK OMEGA, MICRO SIGN vs GREEK MU, SCRIPT l vs l)
# plus NFC for the micro-sign pair. Applied to every symbol on both sides.
def fold_signs(s)
  s.unicode_normalize(:nfc).tr("\u2126\u00B5\u2113", "\u03A9\u03BCl")
end

symbol_map = {}
File.read("#{REPO}/oiml_cs/units/units_db.py").scan(/"([^"]+)":\s*"(u:[^"]+)"/) { |s, id| symbol_map[s] = id }
# Official unitsdb tables via the gem: validated, versioned, bundled data.
# The gem's own find_by_symbol is ascii-only and does no composition, so the
# maps and the composition below are built on its model accessors.
db = Unitsdb.database

def unitsml_id(entity, prefix)
  entity.identifiers.find { |i| i.type == "unitsml" && i.id.start_with?(prefix) }&.id
end

# Lookup priority for shared symbols (unitsdb has 51 collisions: L is both
# liter and lambert, K kayser and kelvin, ...): the frozen pipeline's alias
# table is the original build's disambiguation and wins first; unitsdb
# fills the rest first-wins (stable document order); the local vocabulary
# is authoritative last. candidates keeps every claimant so stored ids can
# be checked against the full collision class.
base_map = {}
candidates = Hash.new { |h, k| h[k] = [] }
symbol_map.each { |s, id| base_map[fold_signs(s)] = id }
db.units.each do |u|
  uid = unitsml_id(u, "u:")
  next unless uid
  Array(u.symbols).each do |sym|
    %i[unicode ascii].each do |k|
      next unless sym.public_send(k).is_a?(String)
      key = fold_signs(sym.public_send(k))
      candidates[key].push(uid)
      base_map[key] = uid unless base_map.key?(key)
    end
  end
end

prefix_by_symbol = {}
db.prefixes.each do |p|
  pid = unitsml_id(p, "p:")
  next unless pid
  Array(p.symbols).each do |sym|
    %i[unicode ascii].each { |k| prefix_by_symbol[fold_signs(sym.public_send(k))] = pid if sym.public_send(k).is_a?(String) }
  end
end

PREFIX_ORDER = prefix_by_symbol.sort_by { |k, _| -k.length }.to_h

local = YAML.safe_load(File.read("#{REPO}/schema/_units_local.yaml"))
compounds = local["compounds"] || {}
counts = local["counts"] || {}
aliases = local["aliases"] || {}
[compounds, counts].each do |section|
  section.each do |id, u|
    Array(u["symbols"]).each do |sym|
      %w[unicode ascii].each do |k|
        next unless sym[k].is_a?(String)
        candidates[fold_signs(sym[k])].push(id)
        base_map[fold_signs(sym[k])] = id
      end
    end
  end
end
aliases.each do |uid, forms|
  Array(forms).each do |form|
    key = fold_signs(form.to_s)
    candidates[key].push(uid)
    base_map[key] = uid
  end
end
symbol_map.each { |s, id| candidates[fold_signs(s)].push(id) }
# ISO 4217 currency spellings — not units; emitted on the record's own
# currency field, never as a u: id.
currency_forms = {}
(local["currencies"] || {}).each do |code, forms|
  Array(forms).each { |form| currency_forms[form.to_s] = code }
end
# Context disambiguation: collision-class symbols resolve only through a
# (recommendation, symbol) row here. The record's R family is the key the
# extraction pipeline cannot silently change, so issuer wording and OCR
# noise on the characteristic heading cannot flip the meaning.
DISAMBIGUATION = Array(local["disambiguation"] || [])

# A symbol is ambiguous when several units claim it and the frozen
# pipeline's reviewed table does not already settle it (L -> liter, K ->
# kelvin). Ambiguous symbols never resolve from the global layers.
AMBIGUOUS = lambda do |symbol|
  claims = candidates[symbol].uniq
  claims.size > 1 && !symbol_map.key?(symbol)
end

CONTEXTUAL_UNIT_ID = lambda do |symbol, family|
  row = DISAMBIGUATION.find { |d| d["symbol"] == symbol && Array(d["r"]).include?(family) }
  row&.dig("unit_id")
end
poc = compounds["u:percent_of_maximum_capacity"]
if poc
  Array(poc["symbols"]).append({ "unicode" => "% of Max", "ascii" => "% of Max" },
                               { "unicode" => "%Emax", "ascii" => "%Emax" })
end

allowed = Set.new
%w[_units.yaml _units_local.yaml].each do |vf|
  doc = YAML.safe_load(File.read("#{REPO}/schema/#{vf}"))
  %w[units prefixes quantities].each do |k|
    next unless doc[k].is_a?(Hash) && doc[k]["enum"]
    doc[k]["enum"].each { |id| allowed.add(id) }
  end
end
compounds.each_key { |id| allowed.add(id) }
counts.each_key { |id| allowed.add(id) }
symbol_map.each_value { |v| allowed.add(v) }
base_map.each_value { |v| allowed.add(v) }
puts "vocabulary: #{symbol_map.size} aliases + #{base_map.size} base symbols · #{allowed.size} allowed ids"

COUNT_CONVENTIONS = %w[divisions digits DN].freeze
COUNT_IDS = counts.keys.to_set

# ─── Compound-unit resolution ────────────────────────────────────────────────
# unitsml compounds: a symbol like "kg/h" parses into a product/quotient
# chain of atoms, each atom resolves against the vocabulary, and the
# composed root-units signature is matched against an index built from
# unitsdb's own root_units declarations plus the local compounds. No
# compound is matched by spelling — only by composition.

nist_unit_map = {}
db.units.each do |u|
  uid = unitsml_id(u, "u:")
  nid = u.identifiers.find { |i| i.type == "nist" }&.id
  nist_unit_map[nid] = uid if uid && nid
end
nist_prefix_map = {}
db.prefixes.each do |p|
  pid = unitsml_id(p, "p:")
  nid = p.identifiers.find { |i| i.type == "nist" }&.id
  nist_prefix_map[nid] = pid if pid && nid
end

def ref_id(ref, map)
  return nil unless ref
  raw = ref.id.to_s
  raw.start_with?("u:", "p:") ? raw : map[raw]
end

root_units_by_id = {}
db.units.each do |u|
  uid = unitsml_id(u, "u:")
  next unless uid
  ru = Array(u.root_units)
  next if ru.empty?
  factors = ru.map { |r| [ref_id(r.prefix_reference, nist_prefix_map), ref_id(r.unit_reference, nist_unit_map), r.power.to_i] }
  # an unmappable factor would corrupt signatures; such units stay identity
  root_units_by_id[uid] = factors unless factors.any? { |_, u2, _| u2.nil? }
end
%w[compounds counts].each do |sec|
  (local[sec] || {}).each do |id, entry|
    ru = entry["root_units"]
    next unless ru.is_a?(Array) && !ru.empty?
    root_units_by_id[id] ||= ru.map { |r| [r.dig("prefix_reference", "id"), r.dig("unit_reference", "id"), r["power"].to_i] }
  end
end

# A declared root factor's own prefix wins; otherwise the atom's carried
# prefix rides along (kg -> encoded kilo; dm^3 parse -> carried deci).
EXPAND_FACTOR = lambda do |uid, prefix, power|
  roots = root_units_by_id[uid]
  if roots
    roots.filter_map { |p, u2, w| [u2, p || prefix, w * power] if u2 }
  else
    [[uid, prefix, power]]
  end
end

def signature(entries)
  entries.map { |e| e.join("~") }.sort.join(";")
end

COMPOUND_INDEX = {}
db.units.each do |u|
  uid = unitsml_id(u, "u:")
  next unless uid
  roots = root_units_by_id[uid]
  next unless roots
  sig = roots.filter_map { |p, u2, w| EXPAND_FACTOR.call(u2, p, w) if u2 }.flatten(1)
  next if sig.empty? || sig.any? { |e| e[0].nil? }
  COMPOUND_INDEX[signature(sig)] ||= uid
end
%w[compounds counts].each do |sec|
  (local[sec] || {}).each do |id, entry|
    ru = entry["root_units"]
    next unless ru.is_a?(Array) && !ru.empty?
    sig = ru.filter_map do |r|
      EXPAND_FACTOR.call(r.dig("unit_reference", "id"), r.dig("prefix_reference", "id"), r["power"].to_i)
    end.flatten(1)
    next if sig.empty? || sig.any? { |e| e[0].nil? }
    COMPOUND_INDEX[signature(sig)] ||= id
  end
end

# Comprehensive unit_symbol -> unitsml ascii normalizer. Idempotent: a
# already-canonical input (e.g. "m^3", "mPa*s") round-trips unchanged.
# Guards keep OIML scale-interval (e) and scale-division (d) notation, and
# the single-uppercase abbreviation pattern (F.S, A.C, D.C) untouched.
SUPER_DIGITS = { "⁰" => "0", "¹" => "1", "²" => "2", "³" => "3", "⁴" => "4",
                 "⁵" => "5", "⁶" => "6", "⁷" => "7", "⁸" => "8", "⁹" => "9" }.freeze

def normalize_unit_symbol(s)
  s = s.to_s.unicode_normalize(:nfc)
  s = s.gsub("µ", "u").gsub("μ", "u")
  s = s.gsub("Ω", "Ohm").gsub("Ω", "Ohm")
  s = s.gsub("ℓ", "l")
  s = s.gsub(/(?<![ed])(⁻?)([⁰¹²³⁴⁵⁶⁷⁸⁹]+)/) do
    sign = $1 == "⁻" ? "-" : ""
    "^#{sign}#{SUPER_DIGITS.values_at(*$2.chars).join}"
  end
  s = s.tr("·×", "**")
  s = s.gsub("°", "deg")
  s = s.gsub(/(?<![A-Z])\.(?=[a-z])/, "*")
  s = s.gsub(/(?<=[A-Za-z])(?<![ed])(\d+)/) { "^#{$1}" }
  # exact equivalence: the cubic decimeter IS the liter (no corpus symbol
  # legitimately retains dm^3 — every dm^3 spelling folds to the liter)
  s = s.gsub("dm^3", "L")
  s
end

def resolve_raw(s, base_map, prefix_order, allowed)
  return nil if AMBIGUOUS.(s)
  return { unit_id: base_map[s], prefix: nil, canonical: s } if base_map.key?(s)
  stripped = s.sub(/\((g|a|abs|gauge|absolute)\)\z/i, "")
  if base_map.key?(stripped)
    return { unit_id: base_map[stripped], prefix: nil, canonical: stripped }
  end
  prefix_order.each do |psym, pid|
    next unless s.start_with?(psym) && s.length > psym.length
    rest = s[psym.length..]
    if base_map.key?(rest) && allowed.include?(base_map[rest])
      return { unit_id: base_map[rest], prefix: pid, canonical: s }
    end
  end
  nil
end

def resolve(symbol, base_map, prefix_order, allowed)
  resolve_raw(symbol, base_map, prefix_order, allowed)
end

# Parse "kg/h", "m^3*kg^-1/s" style chains into atoms with powers, resolve
# each atom, expand through root_units, and look the composed signature up
# in the compound index. Returns a unitsml unit id or nil.
def resolve_compound(symbol, base_map, prefix_order, allowed, index)
  parts = symbol.split("/")
  return nil if parts.length < 2 || parts.length > 3
  entries = []
  parts.each_with_index do |part, pi|
    sign = pi.zero? ? 1 : -1
    part.split("*").each do |atom|
      atom = atom.strip
      next if atom.empty? || atom == "1"
      power = 1
      if (m = atom.match(/\^(-?\d+)\z/))
        power = m[1].to_i
        atom = m.pre_match
      end
      hit = resolve_raw(atom, base_map, prefix_order, allowed)
      return nil unless hit && hit[:unit_id]
      entries.concat(EXPAND_FACTOR.call(hit[:unit_id], hit[:prefix], sign * power))
    end
  end
  return nil if entries.empty? || entries.any? { |e| e[0].nil? }
  index[signature(entries)]
end

# Electrical qualifier decomposition: "Vdc", "V dc", "V (DC)", "Vac/dc",
# "V ac/dc" -> base unit + current_type (AC/DC means the instrument range
# covers both). Returns [base_symbol, current_type] or nil.
ACDC_RE = /\A(.+?)\s*\(?\s*(AC\/DC|DC|AC)\s*\)?\z/i.freeze
ACDC_MODES = { "AC/DC" => "AC_DC", "DC" => "DC", "AC" => "AC" }.freeze

def split_current_qualifier(symbol)
  m = symbol.match(ACDC_RE)
  return nil unless m && m[1] != symbol
  [m[1].strip, ACDC_MODES[m[2].upcase]]
end

# Currency-per-unit and bare currency: "EURO/L" -> [EUR, unit via
# resolve/compound]; "€" -> [EUR, nil]. Returns [code, unit_id] or nil.
def resolve_currency(symbol, currency_forms, base_map, prefix_order, allowed, index)
  if (code = currency_forms[symbol])
    return [code, nil]
  end
  parts = symbol.split("/")
  return nil unless parts.length == 2
  code = currency_forms[parts[0]]
  return nil unless code
  hit = resolve(parts[1], base_map, prefix_order, allowed)&.dig(:unit_id)
  hit ||= resolve_compound(parts[1], base_map, prefix_order, allowed, index)
  hit ? [code, hit] : nil
end

fixed = 0
counted = 0
repaired = 0
unresolved = Hash.new(0)
Dir.glob("#{REPO}/pipeline-work/yaml/R*/**/*.yaml").sort.each do |f|
  y = YAML.unsafe_load_file(f)
  changed = false
  family = f[/\/(R\d+)\//, 1]
  walk = lambda do |node|
    case node
    when Hash
      if node["unit_symbol"].is_a?(String) && !node["unit_symbol"].empty?
        raw = node["unit_symbol"]
        canon = normalize_unit_symbol(raw)
        if canon != raw
          node["unit_symbol"] = canon
          changed = true
        end
        # disambiguation repair: a stored id drawn from the symbol's
        # collision class (bare L stored as u:lambert) or an exact
        # equivalence (deci-cubic-meter IS the liter) is rewritten to the
        # canonical claimant; for ambiguous symbols only the context table
        # may pick, and an uncovered combination is stripped rather than
        # kept as a guess. Model ids outside the class are untouched.
        if node["unit_id"].is_a?(String)
          cands = candidates[canon]
          pref = nil
          if AMBIGUOUS.(canon)
            if cands.include?(node["unit_id"])
              cid = CONTEXTUAL_UNIT_ID.(canon, family)
              pref = { unit_id: cid, prefix: nil }
            end
          elsif !cands.empty? && cands.include?(node["unit_id"])
            pref = resolve(canon, base_map, PREFIX_ORDER, allowed)
          elsif node["unit_id"] == "u:cubic_meter" && node["prefix"] == "p:deci"
            pref = { unit_id: "u:liter", prefix: nil }
          elsif node["unit_id"] == "u:cubic_decimeter"
            pref = { unit_id: "u:liter", prefix: nil }
          end
          if pref && pref[:unit_id] != node["unit_id"]
            node["unit_id"] = pref[:unit_id]
            node["prefix"] = pref[:prefix]
            repaired += 1
            changed = true
          end
        end
        if node["unit_id"].nil?
          sym = canon
          if COUNT_CONVENTIONS.any? { |c| sym.casecmp(c).zero? }
            node["_unit_kind"] = "custom_count"
            counted += 1
            changed = true
          elsif AMBIGUOUS.(sym)
            if (cid = CONTEXTUAL_UNIT_ID.(sym, family))
              node["unit_id"] = cid
              node["prefix"] = nil
              fixed += 1
              changed = true
            else
              unresolved[sym] += 1
            end
          else
            hit = resolve(sym, base_map, PREFIX_ORDER, allowed)
            if hit && hit[:unit_id]
              node["unit_id"] = hit[:unit_id]
              node["prefix"] = hit[:prefix] if hit[:prefix]
              fixed += 1
              changed = true
            elsif (cid = resolve_compound(sym, base_map, PREFIX_ORDER, allowed, COMPOUND_INDEX))
              node["unit_id"] = cid
              fixed += 1
              changed = true
            elsif (cur = resolve_currency(sym, currency_forms, base_map, PREFIX_ORDER, allowed, COMPOUND_INDEX))
              node["currency"] = cur[0]
              node["unit_id"] = cur[1] if cur[1]
              fixed += 1
              changed = true
            elsif (q = split_current_qualifier(sym))
              base, mode = q
              bhit = resolve(base, base_map, PREFIX_ORDER, allowed)
              bid = bhit && bhit[:unit_id]
              bid ||= resolve_compound(base, base_map, PREFIX_ORDER, allowed, COMPOUND_INDEX)
              if bid
                node["unit_id"] = bid
                node["current_type"] = mode
                fixed += 1
                changed = true
              else
                unresolved[sym] += 1
              end
            else
              unresolved[sym] += 1
            end
          end
        end
      end
      node.each_value { |v| walk.(v) if v.is_a?(Hash) || v.is_a?(Array) }
    when Array
      node.each { |v| walk.(v) if v.is_a?(Hash) || v.is_a?(Array) }
    end
  end
  walk.(y)
  next unless changed
  File.write(f, y.to_yaml(line_width: 100).sub(/\A---\n/, ""))
end
puts "unit_ids backfilled this pass: #{fixed} · disambiguation repairs: #{repaired} · counts reclassified as custom_count: #{counted}"
puts "unresolved (top 12): " + unresolved.sort_by { |_k, v| -v }.first(12).map { |k, v| "#{k}=#{v}" }.join(" ")
File.write("#{REPO}/datasets/units-unresolved.json", JSON.pretty_generate(unresolved.sort_by { |_k, v| -v }.to_h))
