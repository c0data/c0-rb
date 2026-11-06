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
    assert_equal "\x1dusers\x01\x1ename\x1famount\x1eAlice\x1f1502.30\x1eBob\x1f340.00".b, buf
    doc = C0::Document.new(buf)
    t = doc["users"]
    assert_equal "users".b, t.name
    assert_equal ["name".b, "amount".b], t.headers
    assert_equal 2, t.record_count
    assert_equal "Alice".b, t.record(0).value(0)
    assert_equal "340.00".b, t.record(1).value(1)
    assert_equal 1, t.column("amount")
    assert C0.canonical?(buf)
    assert_includes doc.warnings, "no SYN at the start of the document"
  end

  def test_syn_heading_and_eot
    buf = C0.build do |b|
      b.syn(shape: "tabular")
      b.group("g", %w[a]) { b.record("1") }
      b.eot
    end
    assert_equal "\x16\x01shape\x1ftabular\x1dg\x01\x1ea\x1e1\x04".b, buf
    doc = C0::Document.new(buf)
    assert doc.has_syn?
    assert doc.has_eot?
    assert_equal "tabular", doc.shape
    assert_equal 1, doc.heading.version
    assert_empty doc.warnings
    assert_equal [["shape".b, "tabular".b]], doc.heading.pairs
  end

  def test_large_field_content_is_shared
    big = "x" * 100
    buf = C0.build { |b| b.record(big) }
    assert_equal big.b, C0::Body.new(buf).record(0).value(0)
  end

  def test_document_files_and_groups
    buf = C0.build do |b|
      b.file("mydb")
      b.group("users", ["name"]) { b.record("Alice") }
      b.group("products", ["id"]) { b.record("01") }
    end
    doc = C0::Document.new(buf)
    assert_equal "mydb".b, doc.name
    assert_equal 2, doc.group_count
    assert_equal ["users".b, "products".b], doc.group_names
    assert_equal "01".b, doc.group("products").record(0).value(0)
    assert_raises(C0::KeyError) { doc.group("missing") }
    assert_equal 2, doc.each_group.count
  end

  def test_text_spelling_and_escapes
    buf = C0.build { |b| b.record("a\x1fb", " padded ", "line\nbreak", "\x02\x10\x17") }
    assert_equal "\x1e\x02a\x1fb\x03\x1f\x02 padded \x03\x1f\x02line\nbreak\x03\x1f\x02\x10\x02\x10\x10\x10\x17\x03".b, buf
    rec = C0::Body.new(buf).record(0)
    assert_equal 4, rec.size
    assert_equal ["a\x1fb".b, " padded ".b, "line\nbreak".b, "\x02\x10\x17".b], rec.values
    assert C0.canonical?(buf)
  end

  def test_separators_count_fields
    assert_equal 2, C0::Body.new("\x1eAlice\x1f".b).record(0).size
    assert_equal 1, C0::Body.new("\x1eAlice".b).record(0).size
    assert_equal [""].map(&:b), C0::Body.new("\x1e".b).record(0).values
  end

  def test_layout_is_not_data
    rec = C0::Body.new("\x1e Alice \x1f Bob\n".b).record(0)
    assert_equal ["Alice".b, "Bob".b], rec.values
    assert_equal " Alice ".b, rec.field(0)
  end

  def test_keyed_record
    buf = C0.build { |b| b.map("host" => "localhost", "port" => "5432") }
    assert_equal "\x1e\x01host\x1flocalhost\x01port\x1f5432".b, buf
    rec = C0::Body.new(buf).record(0)
    assert rec.keyed?
    assert_equal 0, rec.field_count
    assert_equal ["host".b, "port".b], rec.keys
    assert_equal "5432".b, rec["port"]
    assert rec.key?("host")
    assert_nil rec["missing"]
    assert_equal({ "host".b => "localhost".b, "port".b => "5432".b }, rec.to_h)
  end

  def test_duplicate_key_last_wins
    rec = C0::Body.new("\x1e\x01a\x1f1\x01a\x1f2".b).record(0)
    assert_equal ["a".b, "a".b], rec.keys
    assert_equal "2".b, rec["a"]
    refute C0.canonical?("\x1e\x01a\x1f1\x01a\x1f2".b)
  end

  def test_nested_level_and_list
    buf = C0.build do |b|
      b.record("Alice")
      b.list(%w[Admin Editor])
      b.level do
        b.header(%w[street city])
        b.record("1 Main", "Springfield")
      end
      b.list([])
    end
    assert_equal "\x1eAlice\x1f\x10\x1eAdmin\x1fEditor\x18\x1f\x10\x01\x1estreet\x1fcity\x1e1 Main\x1fSpringfield\x18\x1f\x10\x18".b, buf
    rec = C0::Body.new(buf).record(0)
    assert_equal 4, rec.size
    assert_equal ["Admin".b, "Editor".b], rec.list(1)
    inner = rec.level(2)
    assert_equal ["street".b, "city".b], inner.group(0).headers
    assert_equal "Springfield".b, inner.record(0).value(1)
    assert_raises(C0::Error) { rec.list(2) }
    assert_equal [], rec.list(3)
    assert_raises(C0::Error) { rec.value(1) }
    assert_raises(C0::Error) { rec.level(0) }
  end

  def test_keyed_level
    buf = C0.build do |b|
      b.record
      b.key("name", "Alice")
      b.key("address") { b.map("city" => "Springfield") }
    end
    assert_equal "\x1e\x01name\x1fAlice\x01address\x1f\x10\x1e\x01city\x1fSpringfield\x18".b, buf
    rec = C0::Body.new(buf).record(0)
    assert_equal "Springfield".b, rec.level("address").record(0)["city"]
    assert_nil rec.level("missing")
  end

  def test_references
    buf = C0.build do |b|
      b.record("x")
      b.ref("tags")
      b.ref("tags", "001", "label")
    end
    assert_equal "\x1ex\x1f\x05tags\x1f\x05\x02tags\x1f001\x1flabel\x03".b, buf
    rec = C0::Body.new(buf).record(0)
    assert rec.ref(1).group?
    assert_equal "tags".b, rec.ref(1).group
    assert_equal ["tags".b, "001".b, "label".b], rec.ref(2).path
    assert_equal "label".b, rec.ref(2).field
    assert_raises(C0::Error) { rec.ref(0) }
    assert_raises(C0::BuildError) { C0::Builder.new.ref("a", "", "c") }
    assert_raises(C0::BuildError) { C0::Builder.new.ref("a", "b", "c", "d") }
  end

  def test_comments_are_skipped
    body = C0::Body.new("\x07note\x1ea\x07old\x1fb\x07\x1edead\x1ec".b)
    assert_equal 2, body.record_count
    assert_equal ["a".b, "b".b], body.record(0).values
    assert_equal ["c".b], body.record(1).values
    buf = C0.build { |b| b.note("see the runbook"); b.record("a") }
    assert_equal "\x07see the runbook\x1ea".b, buf
    assert_raises(ArgumentError) { C0::Builder.new.note("") }
  end

  def test_names_reject_control_bytes_and_edge_space
    b = C0::Builder.new
    assert_raises(C0::BuildError) { b.group("bad\x1fname") }
    assert_raises(C0::BuildError) { b.group(" padded") }
    assert_raises(C0::BuildError) { b.file("a\nb") }
    assert_raises(C0::BuildError) { b.header("ok", "bad\x02") }
    assert_raises(C0::BuildError) { b.key("k\x1f", "v") }
    assert_raises(C0::BuildError) { b.etb("bad\x1fpayload") }
    assert_equal "".b, b.bytes # a bad name leaves no bytes behind
  end

  def test_level_closed_on_raise
    b = C0::Builder.new
    assert_raises(RuntimeError) { b.level { raise "boom" } }
    assert_equal 0, b.depth
    assert_equal "\x1e\x10\x18".b, b.bytes
  end

  def test_validate_and_errors
    assert_nil C0.validate("\x1dg\x1ea\x1fb".b)
    e = assert_raises(C0::UnassignedCodeError) { C0.validate("\x1ea\x0eb".b) }
    assert_equal 2, e.position
    assert_raises(C0::UnexpectedEndError) { C0.validate("\x1e\x02open".b) }
    assert_raises(C0::SyntaxError) { C0.validate("\x1e\x01a\x1f1\x1f2".b) } # a mixed record
    assert_raises(C0::SyntaxError) { C0.validate("\x1ea\x1ab".b) }         # SUB outside a diff
  end

  def test_container_documents_and_blob
    buf = C0.build do |b|
      b.syn
      b.heading_level("blob") do
        b.header(%w[name offset length])
        b.record("lamp", "0", "3")
        b.record("desk", "3", "4")
      end
      b.eot
      b.syn
      b.group("items", %w[name photo]) { b.record("Lamp", "lamp") }
      b.eot
      b.em("abcdefg")
    end
    cont = C0::Container.new(buf)
    assert_equal 2, cont.documents.size
    assert cont.has_em?
    assert_equal "abcdefg".b, cont.tail
    assert_equal "abc".b, cont.blob("lamp")
    assert_equal "defg".b, cont.blob("desk")
    assert_nil cont.blob("nope")
    assert_empty cont.warnings
    assert_equal "Lamp".b, cont.documents[1]["items"].record(0).value(0)
    assert_raises(C0::SyntaxError) { C0::Container.new("\x1ea\x04\x1eb".b) } # a second document without SYN
  end

  def test_em_without_blob_table_warns
    cont = C0::Container.new("\x16\x1ea\x04\x19raw".b)
    assert_includes cont.warnings, "EM with no blob table: the region is unaddressable"
  end

  def test_stream_torn_tail_and_damaged_block
    r = C0::Stream::Reader.new("\x1ecreate\x1fa1b2\x17\x1e\x02open\x17\x1ename\x1fdra".b)
    assert r.torn?
    assert_equal 2, r.block_count
    assert_equal [1], r.damaged
    assert_equal "\x1ecreate\x1fa1b2".b, r.block(0)
    assert_equal 1, r.records.size
    assert_equal ["create".b, "a1b2".b], r.records[0].values
    assert_equal "\x1ename\x1fdra".b, r.tail
    assert_equal 1, r.table.record_count
  end

  def test_stream_with_heading
    buf = C0.build do |b|
      b.syn(shape: "stream")
      b.etb
      b.record("a", "1")
      b.etb("sha256:00")
      b.record("b", "2")
      b.etb
    end
    r = C0::Stream::Reader.new(buf)
    refute r.torn?
    assert_equal 3, r.block_count
    assert_equal buf.bytesize, r.committed_end
    assert_equal [["a".b, "1".b], ["b".b, "2".b]], r.records.map(&:values)
    assert_equal "stream", r.document.shape
    assert_equal buf.bytesize, C0::Stream.last_commit_end(buf)
  end

  def test_pretty_roundtrip_and_modes
    buf = C0.build do |b|
      b.syn
      b.group("g", %w[name amount]) do
        b.record("Alice", "1")
        b.record("Bob", "1502.30")
      end
      b.eot
    end
    pretty = C0::Pretty.format(buf)
    assert_includes pretty, "␝g"
    assert_includes pretty, "␁␞name␟amount"
    assert_equal buf, C0::Pretty.parse(pretty)
    aligned = C0::Pretty.format(buf, mode: :aligned)
    assert_includes aligned, "␞Alice␟1"
    assert_equal buf, C0::Pretty.parse(aligned)
    spaced = C0.pretty_format(buf, mode: :spaced, indent: "    ")
    assert_includes spaced, "␞ Alice"
    assert_equal buf, C0.pretty_parse(spaced)
    assert_raises(ArgumentError) { C0::Pretty.format(buf, mode: :nope) }
    assert_raises(C0::Pretty::GlyphInDataError) { C0::Pretty.format("\x1e␞".b) }
  end

  def test_pretty_text_kept_verbatim
    buf = C0.build { |b| b.record("note", "line one\nline two") }
    pretty = C0::Pretty.format(buf)
    assert_includes pretty, "␂line one\nline two␃"
    assert_equal buf, C0::Pretty.parse(pretty)
  end

  def test_builder_document_mode_and_chaining
    b = C0::Builder.new
    assert_same b, b.section("intro").section("sub", 2).block("hello\x1fworld").item("one").field("two").etb
    expected = "\x1dintro\x1d\x1dsub\x1e\x02hello\x1fworld\x03\x1fone\x1ftwo\x17"
    assert_equal expected.b, b.bytes
    assert_equal expected.b, b.to_s
  end

  def test_primitives_spell_the_bytes
    g = ->(text) { C0::Pretty.parse(text) }
    assert_equal g["␜inv␝users␁␞name␟amount"],
                 C0.build { |b| b.fs("inv").gs("users").soh.rs("name").us("amount") }
    assert_equal g["␞Alice␟1502.30"], C0.build { |b| b.rs("Alice").us("1502.30") }
    assert_equal g["␞␁host␟localhost␁port␟5432"],
                 C0.build { |b| b.rs.soh("host").us("localhost").soh("port").us("5432") }
    assert_equal g["␞cfg␟␐␞␁b␟2␘"],
                 C0.build { |b| b.rs("cfg").us.dle.rs.soh("b").us("2").can }
    assert_equal g["␇checked␞x"], C0.build { |b| b.bel("checked").rs("x") }
    assert_equal g["␇␝old␞1␝new␞2"],
                 C0.build { |b| b.bel.gs("old").rs("1").gs("new").rs("2") }
    assert_equal g["␝␝sub␞␅users␟␅␂users␟1␃"],
                 C0.build { |b| b.gs.gs("sub").rs.enq("users").us.enq("users", "1") }
    assert_equal g["␖␁version␟1␞a␄"],
                 C0.build { |b| b.syn.soh("version").us("1").rs("a").eot }
    assert_equal "\x17\x17tag\x19tail\xff".b, C0.build { |b| b.etb.etb("tag").em("tail\xff".b) }
    # sub, C0-DIFF only: a replace-all and a pattern with one substitution
    assert_equal g["\u241eold\u241anew"], C0.build { |b| b.rs("old").sub("new") }
    assert_equal g["\u241dx\u241f10\u241a20"], C0.build { |b| b.gs("x").us("10").sub("20") }
    assert_equal "\x1eold\x1a\x02a\x1fb\x03\x1a".b, C0.build { |b| b.rs("old").sub("a\x1fb").sub }
    # values keep the one spelling; names stay names
    assert_equal "\x1e\x02a\x1fb\x03\x1f\x02 x\x03\x07\x02\n\x03".b,
                 C0.build { |b| b.rs("a\x1fb").us(" x").bel("\n") }
    assert_raises(C0::BuildError) { C0::Builder.new.gs("a\x1fb") }
    assert_raises(C0::BuildError) { C0::Builder.new.soh(" k") }
    assert_equal C0.build { |b| b.rs("a").note("n") }, C0.build { |b| b.rs("a").bel("n") }
  end

  def test_primitives_mix_with_composed_methods
    buf = C0.build do |b|
      b.rs("a")
      b.field("b")
      b.record
      b.us("c")
      b.gs("g")
      b.key("k", "v")
      b.group("h", %w[h])
      b.field("x")
    end
    assert_equal C0::Pretty.parse("␞a␟b␞␟c␝g␞␁k␟v␝h␁␞h␞x"), buf
    assert_raises(C0::BuildError) { C0::Builder.new.can }
    assert_raises(C0::BuildError) { C0::Builder.new.rs.enq("a", "b", "c", "d") }
    assert_raises(C0::BuildError) { C0::Builder.new.rs.enq("a", "", "c") }
    assert_raises(ArgumentError) { C0::Builder.new.rs("a").bel("") }
    # a level opened with dle and closed by the block form, and vice versa
    assert_equal "\x1ea\x1f\x10\x1eb\x18\x1fc".b,
                 C0.build { |b| b.rs("a").us.dle.record("b").can.field("c") }
    b = C0::Builder.new.rs("a")
    b.level { b.rs("b").us("c") }
    assert_equal "\x1ea\x1f\x10\x1eb\x1fc\x18".b, b.bytes
    assert_equal 0, b.depth
  end

  def test_both_layers_write_the_same_bytes
    hi = C0.build do |b|
      b.syn(shape: "tabular")
      b.group("users", %w[name amount]) do
        b.record("Alice", "1502.30")
        b.record("Bob", "3 40")
      end
      b.group("cfg")
      b.map("host" => "localhost", "port" => "5432")
      b.record("Carol")
      b.list(%w[Admin Editor])
      b.ref("users", "1")
      b.eot
    end
    lo = C0.build do |b|
      b.syn.soh("shape").us("tabular")
      b.gs("users").soh.rs("name").us("amount").rs("Alice").us("1502.30").rs("Bob").us("3 40")
      b.gs("cfg").rs.soh("host").us("localhost").soh("port").us("5432")
      b.rs("Carol").us.dle.rs("Admin").us("Editor").can.us.enq("users", "1").eot
    end
    assert_equal hi, lo
    assert C0.canonical?(C0::Document.new(lo).body.raw)
  end

  def test_builder_accepts_symbols_and_arrays
    buf = C0.build do |b|
      b.syn("shape" => "key-value", version: "1")
      b.group(:cfg)
      b.map(host: "h", port: "1")
      b.record(%w[x y])
      b.header(%w[a b])
    end
    assert_equal "\x16\x01shape\x1fkey-value\x01version\x1f1\x1dcfg\x1e\x01host\x1fh\x01port\x1f1\x1ex\x1fy\x01\x1ea\x1fb".b, buf
  end

  def test_helpers
    assert C0.assigned?(0x1e)
    refute C0.assigned?(0x0e)
    assert C0.layout?(0x20)
    assert C0.plain?("Alice Smith")
    refute C0.plain?(" Alice")
    refute C0.plain?("a\tb")
    assert_equal "a b".b, C0.trim("  a b\n")
    assert_equal "x\x02y".b, C0.decode_text("x\x10\x02y")
    assert_equal "hi".b, C0.value("\x02hi\x03")
    assert_equal "1.0.0-dev", C0::VERSION
  end

  def test_no_leaks_under_a_loop
    buf = C0.build do |b|
      b.syn(shape: "tabular")
      b.group("g", %w[a b]) { 50.times { |i| b.record(i.to_s, "v\x1f#{i}") } }
      b.eot
    end
    before = nil
    5.times do |round|
      2000.times do
        doc = C0::Document.new(buf)
        doc["g"].each { |r| r.values; r.field(0) }
        C0::Builder.build { |b| b.record("x", "y"); b.level { b.record("z") } }
        C0::Pretty.parse(C0::Pretty.format(buf, mode: :aligned))
        C0::Stream::Reader.new(buf).blocks
      end
      GC.start
      rss = File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
      before = rss if round == 1
      assert rss < before * 1.5 + 20_000, "RSS grew from #{before} to #{rss} kB" if round > 1
    end
  end
end
