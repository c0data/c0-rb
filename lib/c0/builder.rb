# frozen_string_literal: true

module C0
  # Writes C0DATA in canonical compact form. The class and its methods are
  # defined in the C extension (a TypedData object owning a c0_builder); this
  # file adds the Ruby conveniences.
  #
  #   buf = C0::Builder.build do |b|
  #     b.syn(shape: "tabular")
  #     b.group("users", %w[name amount]) do
  #       b.record("Alice", "1502.30")
  #       b.record("Bob", "340.00")
  #     end
  #     b.eot
  #   end
  #
  # Values are byte-transparent and written in their one spelling: plain when
  # they can be, text (STX … ETX) otherwise, with only the seven codes escaped.
  # Names (file, group, header, key, reference segment, ETB payload) must be
  # plain, or a C0::BuildError is raised before anything is written. Every
  # method returns the builder, so calls chain.
  #
  # A record is opened by `record` (or implicitly by the first `field`, `key`,
  # `level`, `list` or `ref`) and ended by the next structural call. Keyed
  # units written right after `syn` belong to the heading. Inside `level { }`
  # the builder is at the top of a fresh body.
  class Builder
    # Drive a fresh builder and return its bytes.
    def self.build
      b = new
      yield b
      b.bytes
    end

    # Alias of `bytes`: the compact form as a binary String.
    def to_s = bytes

    alias to_slice bytes

    # Compatibility spelling of `list`.
    def list_field(items) = list(items)

    def inspect = "#<C0::Builder #{bytesize} bytes, depth #{depth}>"
  end
end
