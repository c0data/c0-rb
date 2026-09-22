# frozen_string_literal: true

# C0DATA — structured data using ASCII C0 control codes.
#
# A thin Ruby layer over the c0 C core (the C0::Ext extension). The read path is
# zero-copy: accessors return shared byteslices into the input buffer.
#
#   buf = C0.build { |b| b.group("users", ["name", "amount"]); b.record("Alice", "100") }
#   t = C0::Table.new(buf)
#   t.record(0).field(0)   # => "Alice"

begin
  require "c0/c0_ext"
rescue LoadError
  require_relative "../ext/c0/c0_ext"
end

module C0
  # Assigned C0 control codes.
  SOH = 0x01
  STX = 0x02
  ETX = 0x03
  EOT = 0x04
  ENQ = 0x05
  DLE = 0x10
  ETB = 0x17
  SUB = 0x1a
  FS  = 0x1c
  GS  = 0x1d
  RS  = 0x1e
  US  = 0x1f

  # Token kinds (matches the C enum order).
  module TokenType
    DATA = 0
    SOH = 1
    STX = 2
    ETX = 3
    EOT = 4
    ENQ = 5
    ETB = 6
    SUB = 7
    FS = 8
    GS = 9
    RS = 10
    US = 11
  end

  module_function

  # Coerce to a binary (ASCII-8BIT) string without copying when already binary.
  def to_bin(str)
    str.encoding == Encoding::BINARY ? str : str.b
  end

  def assigned?(byte)
    Ext.is_assigned(byte)
  end

  # Whether bytes are a canonical document unit for content addressing.
  def canonical?(buf)
    Ext.canonical(to_bin(buf))
  end

  # Decode DLE escapes, returning the logical bytes.
  def unescape(buf)
    Ext.unescape(to_bin(buf))
  end

  # Array of [type, start, end]. Raises ArgumentError on malformed input.
  def tokenize(buf)
    Ext.tokenize(to_bin(buf))
  end

  # Format compact bytes as a human-readable Unicode string.
  def pretty_format(buf, indent = nil)
    indent ? Ext.pretty_format(to_bin(buf), indent) : Ext.pretty_format(to_bin(buf))
  end

  # Parse pretty text back to compact bytes.
  def pretty_parse(text)
    Ext.pretty_parse(text)
  end

  # A record: zero-copy field access over the underlying buffer.
  class Record
    include Enumerable

    def initialize(buf, start, finish)
      @buf = buf
      @start = start
      @end = finish
    end

    def raw = @buf.byteslice(@start, @end - @start)

    def fields = spans.map { |s, e| @buf.byteslice(s, e - s) }

    def field(index)
      s, e = spans[index]
      @buf.byteslice(s, e - s)
    end

    # Field at +index+ with DLE escapes decoded.
    def value(index) = C0.unescape(field(index))

    def values = spans.map { |s, e| C0.unescape(@buf.byteslice(s, e - s)) }

    # Field at +index+ read as a list (STX items-separated-by-US ETX), each
    # item unescaped. A plain field yields one item; an empty scope yields [].
    def list(index)
      s, e = spans[index]
      Ext.field_items(@buf, s, e).map { |is, ie| C0.unescape(@buf.byteslice(is, ie - is)) }
    end

    def size = spans.size

    def each
      return enum_for(:each) unless block_given?

      spans.each { |s, e| yield @buf.byteslice(s, e - s) }
    end

    private

    def spans = Ext.record_fields(@buf, @start, @end)
  end

  # A tabular group: name, headers, and records.
  class Table
    include Enumerable

    def initialize(buf, offset = 0)
      @buf = C0.to_bin(buf)
      ns, ne, @headers, @records = Ext.table(@buf, offset)
      @name = [ns, ne]
    end

    def name = @buf.byteslice(@name[0], @name[1] - @name[0])

    def headers = @headers.map { |s, e| @buf.byteslice(s, e - s) }

    def header_count = @headers.size

    def record_count = @records.size

    def record(index)
      s, e = @records[index]
      Record.new(@buf, s, e)
    end

    def records = (0...@records.size).map { |i| record(i) }

    def size = @records.size

    def each
      return enum_for(:each) unless block_given?

      @records.each { |s, e| yield Record.new(@buf, s, e) }
    end
  end

  # A group within a document; read it as a Table.
  class Group
    def initialize(buf, start, finish)
      @buf = buf
      @start = start
      @end = finish
    end

    def table = Table.new(@buf, @start)

    def name = table.name

    def raw = @buf.byteslice(@start, @end - @start)

    def record(index) = table.record(index)

    def record_count = table.record_count
  end

  # A full document: navigate its top-level groups.
  class Document
    include Enumerable

    def initialize(buf)
      @buf = C0.to_bin(buf)
      ns, ne, @groups = Ext.document(@buf)
      @name = [ns, ne]
    end

    def name = @buf.byteslice(@name[0], @name[1] - @name[0])

    def group_count = @groups.size

    def group(index)
      s, e = @groups[index]
      Group.new(@buf, s, e)
    end

    def group_by_name(name)
      needle = C0.to_bin(name)
      each { |g| return g if g.name == needle }
      nil
    end

    def size = @groups.size

    def each
      return enum_for(:each) unless block_given?

      @groups.each { |s, e| yield Group.new(@buf, s, e) }
    end
  end

  # An append-only log: committed region, torn-tail detection, blocks.
  class StreamReader
    attr_reader :committed_end

    def initialize(buf)
      @buf = C0.to_bin(buf)
      @committed_end, @torn, @blocks = Ext.stream(@buf)
    end

    def torn? = @torn

    def committed = @buf.byteslice(0, @committed_end)

    def tail = @buf.byteslice(@committed_end, @buf.bytesize - @committed_end)

    def block_count = @blocks.size

    def block(index)
      s, e = @blocks[index]
      @buf.byteslice(s, e - s)
    end

    def blocks = @blocks.map { |s, e| @buf.byteslice(s, e - s) }

    def table = Table.new(committed)
  end

  # Builds C0DATA compact bytes. Byte-identical to the C builder.
  #
  # Names (file/group/header) reject control bytes; record field values are
  # byte-transparent and DLE-escaped automatically.
  class Builder
    def initialize
      @buf = +"".b
    end

    def file(name)
      @buf << FS
      write_name(name)
      self
    end

    def group(name, headers = nil)
      @buf << GS
      write_name(name)
      header(headers) if headers
      self
    end

    def header(names)
      @buf << SOH
      names.each_with_index do |n, i|
        @buf << US if i.positive?
        write_name(n)
      end
      self
    end

    def record(*fields)
      fields = fields[0] if fields.size == 1 && fields[0].is_a?(Array)
      @buf << RS
      fields.each_with_index do |f, i|
        @buf << US if i.positive?
        write_escaped(f)
      end
      self
    end

    def eot
      @buf << EOT
      self
    end

    # ETB commit marker (stream mode) with an optional integrity payload,
    # which may not contain control bytes.
    def etb(payload = nil)
      @buf << ETB
      if payload
        b = C0.to_bin(payload)
        b.each_byte { |x| raise ArgumentError, "ETB payload may not contain control bytes" if x < 0x20 }
        @buf << b
      end
      self
    end

    # Nested sub-structure: STX, the block's output, ETX.
    def nested
      @buf << STX
      yield self
      @buf << ETX
      self
    end

    # Reference: ENQ + name, or with 2+ segments ENQ STX segments-joined-by-US ETX.
    def ref(*path)
      @buf << ENQ
      if path.size == 1
        write_name(path[0])
      else
        @buf << STX
        path.each_with_index do |seg, i|
          @buf << US if i.positive?
          write_name(seg)
        end
        @buf << ETX
      end
      self
    end

    # Field whose value is a flat list: US STX items-joined-by-US ETX. Read back with Record#list.
    def list_field(items)
      @buf << US << STX
      items.each_with_index do |it, i|
        @buf << US if i.positive?
        write_escaped(it)
      end
      @buf << ETX
      self
    end

    # Single field: US + escaped value (for building records field by field).
    def field(value)
      @buf << US
      write_escaped(value)
      self
    end

    # Document-mode section: GS x depth + name.
    def section(name, depth = 1)
      depth.times { @buf << GS }
      write_name(name)
      self
    end

    # Document-mode content block: RS + escaped text.
    def block(text)
      @buf << RS
      write_escaped(text)
      self
    end

    # Document-mode list item: US + escaped text.
    def item(text)
      @buf << US
      write_escaped(text)
      self
    end

    def bytes = @buf.dup

    private

    def write_name(str)
      b = C0.to_bin(str)
      b.each_byte { |x| raise ArgumentError, "names may not contain control bytes" if x < 0x20 }
      @buf << b
    end

    def write_escaped(str)
      C0.to_bin(str).each_byte do |x|
        @buf << DLE if x < 0x20
        @buf << x
      end
    end
  end

  # Build a buffer by driving a fresh builder, returning its bytes.
  def self.build
    b = Builder.new
    yield b
    b.bytes
  end
end
