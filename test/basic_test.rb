# frozen_string_literal: true

require "minitest/autorun"
require "c0"

class BasicTest < Minitest::Test
  def test_build_read_roundtrip
    buf = C0.build do |b|
      b.group("users", %w[name amount])
      b.record("Alice", "1502.30")
      b.record("Bob", "340.00")
    end
    t = C0::Table.new(buf)
    assert_equal "users".b, t.name
    assert_equal ["name".b, "amount".b], t.headers
    assert_equal 2, t.record_count
    assert_equal "Alice".b, t.record(0).field(0)
    assert_equal "340.00".b, t.record(1).field(1)
    assert C0.canonical?(buf)
  end

  def test_large_field_content
    big = "x" * 100 # large enough to be a shared (zero-copy) substring
    buf = C0.build { |b| b.group("g"); b.record(big) }
    assert_equal big.b, C0::Table.new(buf).record(0).field(0)
  end

  def test_document
    buf = C0.build do |b|
      b.file("mydb")
      b.group("users", ["name"])
      b.record("Alice")
      b.group("products", ["id"])
      b.record("01")
    end
    doc = C0::Document.new(buf)
    assert_equal "mydb".b, doc.name
    assert_equal 2, doc.group_count
    assert_equal "01".b, doc.group_by_name("products").record(0).field(0)
    assert_nil doc.group_by_name("missing")
  end

  def test_escaping
    buf = C0.build { |b| b.group("g"); b.record("a\x1fb", "c") }
    rec = C0::Table.new(buf).record(0)
    assert_equal 2, rec.size
    assert_equal "a\x1fb".b, rec.value(0)
  end

  def test_trailing_empty_field
    assert_equal 2, C0::Table.new("\x1eAlice\x1f".b).record(0).size
    assert_equal 1, C0::Table.new("\x1eAlice".b).record(0).size
  end

  def test_names_reject_control_bytes
    assert_raises(ArgumentError) { C0::Builder.new.group("bad\x1fname") }
  end

  def test_stream_torn_tail
    r = C0::StreamReader.new("\x1ecreate\x1fa1b2\x17\x1ename\x1fdra".b)
    assert r.torn?
    assert_equal 1, r.block_count
    assert_equal 1, r.table.record_count
  end

  def test_pretty_roundtrip
    buf = C0.build { |b| b.group("g", %w[a b]); b.record("x", "y") }
    pretty = C0.pretty_format(buf)
    assert_includes pretty, "␞" # RS glyph
    assert_equal buf, C0.pretty_parse(pretty)
  end
end
