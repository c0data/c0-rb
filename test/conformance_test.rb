# frozen_string_literal: true

# Runs the shared conformance vectors from the c0-spec submodule.
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

  # A field is a JSON string (UTF-8 bytes) or {"hex" => "..."} (raw bytes).
  def field_bytes(field)
    field.is_a?(String) ? field.b : hexbytes(field["hex"])
  end
end

class DecodeConformanceTest < Minitest::Test
  def check_table(table, group)
    assert_equal group["name"].b, table.name
    if group["headers"]
      assert_equal group["headers"].map(&:b), table.headers
    else
      assert_equal 0, table.header_count
    end
    records = group["records"]
    assert_equal records.size, table.record_count
    records.each_with_index do |row, i|
      rec = table.record(i)
      assert_equal row.size, rec.size
      row.each_with_index { |f, j| assert_equal Conformance.field_bytes(f), rec.value(j) }
    end
  end

  def test_decode
    Conformance.cases("decode.json").each do |c|
      buf = Conformance.hexbytes(c["bytes"])
      groups = c["groups"]
      if c["file"].nil? && groups.size == 1 && groups[0]["name"] == ""
        check_table(C0::Table.new(buf), groups[0])
      else
        doc = C0::Document.new(buf)
        assert_equal (c["file"] || "").b, doc.name
        assert_equal groups.size, doc.group_count
        groups.each_with_index { |g, i| check_table(doc.group(i).table, g) }
      end
    end
  end
end

class EncodeConformanceTest < Minitest::Test
  def test_encode
    Conformance.cases("encode.json").each do |c|
      spec = c["build"]
      b = C0::Builder.new
      b.file(spec["file"]) if spec["file"]
      spec["groups"].each do |g|
        b.group(g["name"], g["headers"])
        g["records"].each { |row| b.record(row.map { |f| Conformance.field_bytes(f) }) }
      end
      buf = b.bytes
      assert_equal Conformance.hexbytes(c["canonical"]), buf, c["name"]
      assert C0.canonical?(buf), c["name"]
    end
  end
end

class ListConformanceTest < Minitest::Test
  def test_list
    Conformance.cases("list.json").each do |c|
      buf = Conformance.hexbytes(c["bytes"])
      rec = C0::Table.new(buf).record(0)
      record = c["record"]
      assert_equal record.size, rec.size, c["name"]
      record.each_with_index do |entry, i|
        if entry.is_a?(Array)
          assert_equal entry.map { |f| Conformance.field_bytes(f) }, rec.list(i), c["name"]
        else
          assert_equal Conformance.field_bytes(entry), rec.value(i), c["name"]
        end
      end
      next unless c["canonical"]

      b = C0::Builder.new
      b.record(Conformance.field_bytes(record[0]))
      record[1..].each do |entry|
        if entry.is_a?(Array)
          b.list_field(entry.map { |f| Conformance.field_bytes(f) })
        else
          b.field(Conformance.field_bytes(entry))
        end
      end
      assert_equal c["bytes"], b.bytes.unpack1("H*"), c["name"]
      assert C0.canonical?(b.bytes), c["name"]
    end
  end
end

class CanonicalConformanceTest < Minitest::Test
  def test_canonical
    Conformance.cases("canonical.json").each do |c|
      buf = Conformance.hexbytes(c["bytes"])
      wellformed =
        begin
          C0.tokenize(buf)
          true
        rescue ArgumentError
          false
        end
      assert_equal c["wellformed"], wellformed, c["name"]
      assert_equal c["canonical"], C0.canonical?(buf), c["name"]
    end
  end
end

class InvalidConformanceTest < Minitest::Test
  def test_invalid
    Conformance.cases("invalid.json").each do |c|
      assert_raises(ArgumentError, c["name"]) { C0.tokenize(Conformance.hexbytes(c["bytes"])) }
    end
  end
end

class StreamConformanceTest < Minitest::Test
  def test_stream
    Conformance.cases("stream.json").each do |c|
      buf = Conformance.hexbytes(c["bytes"])
      r = C0::StreamReader.new(buf)
      assert_equal c["committed_end"], r.committed_end, c["name"]
      assert_equal c["torn"], r.torn?, c["name"]
      assert_equal c["blocks"].size, r.block_count, c["name"]
      c["blocks"].each_with_index { |h, i| assert_equal Conformance.hexbytes(h), r.block(i) }
      next unless c["records"]

      t = r.table
      assert_equal c["records"].size, t.record_count
      c["records"].each_with_index { |row, i| assert_equal row.map(&:b), t.record(i).values }
    end
  end
end
