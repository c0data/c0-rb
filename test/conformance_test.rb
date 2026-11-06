# frozen_string_literal: true

# Runs the shared conformance vectors from the c0-spec submodule
# (https://github.com/c0data/c0-spec), the source of truth. Schema v2: see
# c0-spec/vectors/README.md. The checks mirror the Crystal reference harness
# (c0-cr/spec/conformance_spec.cr).
require "minitest/autorun"
require "json"
require "c0"

module Conformance
  VEC = File.expand_path("../c0-spec/vectors", __dir__)

  module_function

  def cases(name)
    JSON.parse(File.read(File.join(VEC, name)))["cases"]
  end

  def hexbytes(hex)
    [hex].pack("H*")
  end

  # A scalar expected value: a JSON string (UTF-8 bytes) or {"hex" => "..."}.
  def scalar?(f)
    f.is_a?(String) || (f.is_a?(Hash) && f.key?("hex"))
  end

  def scalar_bytes(f)
    f.is_a?(String) ? f.b : hexbytes(f["hex"])
  end

  # Flatten a group list with "sections" into [depth, group] pairs.
  def flat_groups(groups, depth = 1)
    groups.flat_map do |g|
      [[depth, g]] + flat_groups(g["sections"] || [], depth + 1)
    end
  end
end

# Shared assertions over the decoded structure.
module ConformanceChecks
  include Conformance

  def check_value(rec, i, f, name)
    if scalar?(f)
      assert_equal scalar_bytes(f), rec.value(i), name
    elsif f.key?("level")
      check_body(rec.level(i), f["level"], name)
    elsif f.key?("ref")
      r = rec.ref(i)
      expected = f["ref"].is_a?(String) ? [f["ref"].b] : f["ref"].map(&:b)
      assert_equal expected, r.path, name
    else
      raise "unknown value form #{f}"
    end
  end

  def check_record(rec, r, name)
    if r.is_a?(Array)
      refute rec.keyed?, name
      assert_equal r.size, rec.field_count, name
      r.each_with_index { |f, j| check_value(rec, j, f, name) }
    else
      assert rec.keyed?, name
      pairs = r["keys"]
      assert_equal pairs.map { |p| p[0].b }, rec.keys, name
      got = rec.pairs
      pairs.each_with_index { |p, j| assert_equal scalar_bytes(p[1]), got[j][1], name }
    end
  end

  def check_group(g, e, name)
    assert_equal e["name"].b, g.name, name
    if e["headers"]
      assert_equal e["headers"].map(&:b), g.headers, name
    else
      refute g.header?, name
    end
    records = e["records"]
    assert_equal records.size, g.record_count, name
    records.each_with_index { |r, i| check_record(g.record(i), r, name) }
  end

  def check_groups(groups, expected, name)
    flat = flat_groups(expected)
    assert_equal flat.size, groups.size, name
    flat.each_with_index do |(depth, e), i|
      g = groups[i]
      check_group(g, e, name)
      # the unnamed leading group has depth 0 in the reader
      assert_equal depth, g.depth, name unless e["name"].empty? && i.zero?
    end
  end

  def check_files(body, files, name)
    assert_equal files.size, body.files.size, name
    files.each_with_index do |f, i|
      assert_equal f["name"].b, body.files[i].name, name
      check_groups(body.files[i].groups, f["groups"], name)
    end
  end

  def check_body(body, e, name)
    if e.key?("files")
      check_files(body, e["files"], name)
    elsif e.key?("records")
      # a level described as a single table: one unnamed file, at most one group
      assert_equal 1, body.files.size, name
      gs = body.files[0].groups
      if e["records"].empty? && e["headers"].nil?
        assert_equal 0, gs.size, name
      else
        assert_equal 1, gs.size, name
        check_group(gs[0], { "name" => "", "headers" => e["headers"], "records" => e["records"] }, name)
      end
    else
      check_groups(body.groups, e["groups"], name)
    end
  end

  def check_heading(h, pairs, name)
    assert_equal pairs.map { |p| p[0].b }, h.keys, name
    pairs.each_with_index do |(k, v), i|
      if scalar?(v)
        assert_equal scalar_bytes(v), h.pairs[i][1], name
      elsif v.key?("level")
        check_body(h.level(k), v["level"], name)
      end
    end
  end

  # ---- building ------------------------------------------------------------

  def build_value(b, f)
    if scalar?(f)
      b.field(scalar_bytes(f))
    elsif f.key?("level")
      b.level { build_body(b, f["level"]) }
    elsif f.key?("ref")
      b.ref(*Array(f["ref"]))
    elsif f.key?("map")
      b.level { build_record(b, { "keys" => f["map"] }) }
    else
      raise "unknown value form #{f}"
    end
  end

  def build_record(b, r)
    b.record
    if r.is_a?(Array)
      r.each { |f| build_value(b, f) }
    else
      r["keys"].each do |k, v|
        if scalar?(v)
          b.key(k, scalar_bytes(v))
        elsif v.key?("map")
          b.key(k) { build_record(b, { "keys" => v["map"] }) }
        elsif v.key?("level")
          b.key(k) { build_body(b, v["level"]) }
        end
      end
    end
  end

  def build_groups(b, groups)
    groups.each_with_index do |g, i|
      headers = g["headers"]
      if g["name"].empty? && i.zero?
        b.header(headers) if headers # the unnamed leading group: no GS
      else
        b.group(g["name"], headers)
      end
      g["records"].each { |r| build_record(b, r) }
    end
  end

  def build_body(b, e)
    if e.key?("records")
      b.header(e["headers"]) if e["headers"]
      e["records"].each { |r| build_record(b, r) }
    elsif e.key?("groups")
      build_groups(b, e["groups"])
    end
  end
end

class DecodeConformanceTest < Minitest::Test
  include ConformanceChecks

  Conformance.cases("decode.json").each do |c|
    define_method("test_decode_#{c['name']}") do
      name = c["name"]
      bytes = hexbytes(c["bytes"])
      cont = C0::Container.new(bytes)
      if (docs = c["documents"])
        assert_equal docs.size, cont.documents.size, name
        docs.each_with_index do |d, i|
          doc = cont.documents[i]
          check_heading(doc.heading, d["heading"], name) if d["heading"]
          assert_equal (d["file"] || "").b, doc.name, name
          check_groups(doc.groups, d["groups"], name)
        end
      else
        doc = cont.first
        if (h = c["heading"])
          assert doc.has_syn?, name
          check_heading(doc.heading, h, name)
        end
        if (files = c["files"])
          check_files(doc.body, files, name)
        else
          assert_equal (c["file"] || "").b, doc.name, name
          check_groups(doc.groups, c["groups"], name)
        end
        if (tail = c["tail"])
          assert cont.has_em?, name
          assert_equal tail, cont.tail.unpack1("H*"), name
        end
      end
    end
  end
end

class EncodeConformanceTest < Minitest::Test
  include ConformanceChecks

  Conformance.cases("encode.json").each do |c|
    define_method("test_encode_#{c['name']}") do
      name = c["name"]
      build = c["build"]
      emit = lambda do |b|
        b.file(build["file"]) if build["file"]
        build_groups(b, build["groups"])
      end
      canonical = C0::Builder.build { |b| emit.call(b) }
      assert_equal c["canonical"], canonical.unpack1("H*"), name
      assert C0.canonical?(canonical), name
      if (h = build["heading"])
        whole = C0::Builder.build do |b|
          b.syn(h.to_h)
          emit.call(b)
          b.eot
        end
        assert_equal c["bytes"], whole.unpack1("H*"), name
      end
    end
  end
end

class CanonicalConformanceTest < Minitest::Test
  Conformance.cases("canonical.json").each do |c|
    define_method("test_canonical_#{c['name']}") do
      bytes = Conformance.hexbytes(c["bytes"])
      wellformed =
        begin
          C0.validate(bytes)
          true
        rescue C0::Error
          false
        end
      assert_equal c["wellformed"], wellformed, c["name"]
      assert_equal c["canonical"], C0.canonical?(bytes), c["name"]
    end
  end
end

class InvalidConformanceTest < Minitest::Test
  Conformance.cases("invalid.json").each do |c|
    define_method("test_invalid_#{c['name']}") do
      assert_raises(C0::Error, c["name"]) { C0.validate(Conformance.hexbytes(c["bytes"])) }
    end
  end
end

class NestedConformanceTest < Minitest::Test
  include ConformanceChecks

  Conformance.cases("nested.json").each do |c|
    define_method("test_nested_#{c['name']}") do
      name = c["name"]
      bytes = hexbytes(c["bytes"])
      expected = c["record"]
      rec = C0::Body.new(bytes).record(0)
      assert_equal expected.size, rec.field_count, name
      expected.each_with_index do |f, i|
        if scalar?(f)
          assert_equal scalar_bytes(f), rec.value(i), name
        elsif (items = f["list"])
          if items.all? { |x| scalar?(x) }
            assert_equal items.map { |x| scalar_bytes(x) }, rec.list(i), name
          else
            inner = rec.level(i).record(0)
            assert_equal items.size, inner.field_count, name
            items.each_with_index do |x, j|
              if scalar?(x)
                assert_equal scalar_bytes(x), inner.value(j), name
              else
                assert_equal x["list"].map { |y| scalar_bytes(y) }, inner.list(j), name
              end
            end
          end
        elsif f.key?("level")
          check_body(rec.level(i), f["level"], name)
          assert_raises(C0::Error, name) { rec.list(i) }
        end
      end
      next unless c["canonical"]

      buf = C0::Builder.build do |b|
        b.record
        expected.each do |f|
          if !scalar?(f) && (items = f["list"]) && items.all? { |x| scalar?(x) }
            b.list(items.map { |x| scalar_bytes(x) })
          elsif !scalar?(f) && (items = f["list"])
            b.level do
              b.record
              items.each do |x|
                if scalar?(x)
                  b.field(scalar_bytes(x))
                else
                  b.list(x["list"].map { |y| scalar_bytes(y) })
                end
              end
            end
          else
            build_value(b, f)
          end
        end
      end
      assert_equal c["bytes"], buf.unpack1("H*"), name
      assert C0.canonical?(buf), name
    end
  end
end

class StreamConformanceTest < Minitest::Test
  Conformance.cases("stream.json").each do |c|
    define_method("test_stream_#{c['name']}") do
      name = c["name"]
      bytes = Conformance.hexbytes(c["bytes"])
      r = C0::Stream::Reader.new(bytes)
      assert_equal c["committed_end"], r.committed_end, name
      assert_equal c["torn"], r.torn?, name
      assert_equal c["blocks"].size, r.block_count, name
      c["blocks"].each_with_index { |hex, i| assert_equal hex, r.block(i).unpack1("H*"), name }
      assert_equal (c["damaged"] || []), r.damaged, name
      next unless (records = c["records"])

      got = r.records
      assert_equal records.size, got.size, name
      records.each_with_index { |row, i| assert_equal row.map(&:b), got[i].values, name }
    end
  end
end
