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
  # Two layers. The primitives are one method per code (`fs`, `gs`, `rs`,
  # `us`, `sub`, `soh`, `dle`, `can`, `bel`, `enq`, `syn`, `eot`, `etb`, `em`);
  # each writes its code and, when given, what grammatically follows it, so a
  # chain reads like the bytes (`sub` is C0-DIFF only: `rs("old").sub("new")`
  # writes a replace-all, ␞old␚new; in a data body SUB is an error):
  #
  #   b.rs("Alice").us("1502.30")                              # ␞Alice␟1502.30
  #   b.rs.soh("host").us("localhost").soh("port").us("5432")  # ␞␁host␟localhost␁port␟5432
  #   b.gs("users").soh.rs("name").us("amount")                # ␝users␁␞name␟amount
  #   b.bel.gs("old")                                          # ␇␝old, a dead group
  #
  # The composed methods (`file`, `group`, `header`, `record`, `field`, `map`,
  # `key`, `level`, `list`, `ref`, `note`) are built on the primitives and
  # cannot write ill-formed output. The primitives write what you spell;
  # well-formedness is then yours to keep. Both layers share the record state,
  # so they mix: `b.rs("a").field("b")` writes ␞a␟b.
  #
  # Values are byte-transparent and written in their one spelling: plain when
  # they can be, text (STX … ETX) otherwise, with only the seven codes escaped;
  # there is no STX/ETX primitive, so everything written stays canonical.
  # Names (file, group, header, key, reference segment, ETB payload) must be
  # plain, or a C0::BuildError is raised before anything is written. Every
  # method returns the builder, so calls chain.
  #
  # A record is opened by `record` or `rs` (or implicitly by the first `field`,
  # `key`, `level`, `list` or `ref`) and ended by the next structural call.
  # Keyed units written right after `syn` belong to the heading. Inside
  # `level { }` (or between `dle` and `can`) the builder is at the top of a
  # fresh body.
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
