# frozen_string_literal: true

# C0DATA 1.0 — structured data using ASCII C0 control codes.
#
# A thin Ruby layer over the c0 C core (the C0::Ext extension). The read path
# is zero-copy: accessors return shared byteslices into the input buffer.
#
#   buf = C0.build do |b|
#     b.syn(shape: "tabular")
#     b.group("users", %w[name amount]) do
#       b.record("Alice", "1502.30")
#       b.record("Bob", "340.00")
#     end
#     b.eot
#   end
#   doc = C0::Document.new(buf)
#   doc["users"].record(0).value(0)   # => "Alice"
#
# Reading is a two-step contract, as in the C core: `C0.validate` checks a
# buffer against the grammar once; the navigators (Document, Body, Group,
# Record) then assume well-formed input and raise only on the malformations
# they happen to meet.

begin
  require "c0/c0_ext"
rescue LoadError
  require_relative "../ext/c0/c0_ext"
end

module C0
  # Assigned C0 control codes (DESIGN.md "Assigned Control Codes").
  SOH = 0x01 # Heading: a key for the value after it, or SOH RS a header row
  STX = 0x02 # Start of text (a literal value)
  ETX = 0x03 # End of text
  EOT = 0x04 # End of document
  ENQ = 0x05 # Reference
  BEL = 0x07 # Comment: a note, or marks the next element dead
  DLE = 0x10 # Recurse: opens a nested level (outside text); escape (inside text)
  SYN = 0x16 # Start of document, then the heading
  ETB = 0x17 # Commit marker (stream mode)
  CAN = 0x18 # Close a nested level
  EM  = 0x19 # End of medium: a raw blob follows
  SUB = 0x1a # Substitution (C0-DIFF only)
  FS  = 0x1c # File separator
  GS  = 0x1d # Group separator
  RS  = 0x1e # Record separator
  US  = 0x1f # Unit separator

  # Layout codes outside text.
  HT = 0x09
  LF = 0x0a
  CR = 0x0d
  SP = 0x20

  # What a raw unit holds, by its first non-layout byte (matches the C enum).
  module UnitType
    PLAIN = 0
    TEXT = 1
    LEVEL = 2
    REF = 3
  end

  module_function

  # Coerce to a binary (ASCII-8BIT) String without copying when already binary.
  def to_bin(str)
    str = str.to_s unless str.is_a?(String)
    str.encoding == Encoding::BINARY ? str : str.b
  end

  # Whether a byte is one of the sixteen assigned codes.
  def assigned?(byte) = Ext.is_assigned(byte)

  # Whether a byte is layout outside text (SP, HT, LF, CR).
  def layout?(byte) = Ext.is_layout(byte)

  # Whether a byte is a control code (below 0x20).
  def control?(byte) = byte < 0x20

  # Whether a value can be written plain: no byte below 0x20, no edge whitespace.
  def plain?(value) = Ext.is_plain(to_bin(value))

  # Whether bytes are a legal name (label, key, header name): the same test as plain.
  def name?(value) = Ext.is_plain(to_bin(value))

  # Layout trimmed from both ends of a raw slice.
  def trim(raw) = Ext.trim(to_bin(raw))

  # Check a whole buffer against the grammar. Raises a C0::SyntaxError (or a
  # subclass) on the first error; returns nil when well-formed.
  def validate(buf)
    Ext.validate(to_bin(buf))
  end

  # Whether bytes are a canonical unit: well-formed, no layout, one spelling
  # per value, unique keys in each keyed record, no framing, no comments.
  def canonical?(buf) = Ext.canonical(to_bin(buf))

  # The logical value of a raw unit: a plain value trimmed, or the inside of a
  # text with its escapes decoded. Raises C0::Error on a level or reference.
  def value(raw)
    b = to_bin(raw)
    Ext.value(b, 0, b.bytesize)
  end

  # Decode the inside of a text (the bytes between STX and ETX).
  def decode_text(inside) = Ext.decode_text(to_bin(inside))

  # Build a buffer by driving a fresh Builder, returning its bytes.
  def build(&) = Builder.build(&)

  # Pretty form (Unicode Control Pictures) of compact bytes.
  def pretty_format(buf, indent: "  ", mode: :compact) = Pretty.format(buf, indent: indent, mode: mode)

  # Compact bytes from pretty form.
  def pretty_parse(text) = Pretty.parse(text)
end

require_relative "c0/body"
require_relative "c0/document"
require_relative "c0/builder"
require_relative "c0/stream"
require_relative "c0/pretty"
