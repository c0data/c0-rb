# frozen_string_literal: true

module C0
  # Pretty form: Unicode Control Pictures (U+2400 block) for the codes, line
  # breaks and indentation as layout. `format` and `parse` are inverses on
  # well-formed input. GlyphInDataError (a C0::Error) is raised when a value
  # holds a Control Picture character and cannot be shown unambiguously.
  module Pretty
    MODES = { compact: 0, aligned: 1, spaced: 2 }.freeze

    module_function

    # The glyph for a code byte.
    def glyph(byte) = (0x2400 + byte).chr(Encoding::UTF_8)

    # Compact bytes → pretty form (a UTF-8 String). `mode` is :compact (one
    # element per line), :aligned (table columns aligned) or :spaced (aligned,
    # plus a space after each prefix and around the US glyph).
    def format(buf, indent: "  ", mode: :compact)
      m = MODES.fetch(mode) { raise ArgumentError, "unknown mode #{mode.inspect}; use #{MODES.keys.inspect}" }
      Ext.pretty_format(C0.to_bin(buf), indent, m)
    end

    # Pretty form → compact bytes. Glyphs become codes; outside text,
    # whitespace touching a glyph or a line edge is dropped.
    def parse(text) = Ext.pretty_parse(text.to_s.encode(Encoding::UTF_8))
  end
end
