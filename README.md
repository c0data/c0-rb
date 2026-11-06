# c0

A Ruby implementation of [C0DATA](https://github.com/c0data) 1.0 — structured
data built on ASCII C0 control codes.

This is **not** a reimplementation: it's a thin, fast binding over the
[c0 C core](https://github.com/c0data/c0-c) (a Ruby C extension, no runtime
dependencies), so the scan-heavy work runs as native C while the Ruby layer
provides an idiomatic API. The read path is **zero-copy** — accessors return
shared byteslices into the input buffer.

## Usage

```ruby
require "c0"

# Write: ␖␁shape␟tabular␝users␁␞name␟amount␞Alice␟1502.30␞Bob␟340.00␄
buf = C0.build do |b|
  b.syn(shape: "tabular")
  b.group("users", %w[name amount]) do   # ␝users then the header row ␁␞name␟amount
    b.record("Alice", "1502.30")
    b.record("Bob", "340.00")
  end
  b.eot
end

# Read (zero-copy: values are shared byteslices of buf)
doc = C0::Document.new(buf)
doc.shape                       # => "tabular"
doc["users"].headers            # => ["name", "amount"]
doc["users"].each do |rec|
  name, amount = rec.values     # logical values: text decoded, layout trimmed
  rec.value(0)                  # => "Alice"
end

# Canonical form is hashable for content addressing
C0.canonical?(doc.body.raw)     # => true

# Streams, containers, pretty form
C0::Stream::Reader.new(File.binread("events.c0"))   # #torn?, #committed, #blocks, #records
C0::Container.new(buf)                              # several documents, EM tail, #blob(name)
C0::Pretty.format(buf, mode: :aligned)              # Unicode Control Pictures
```

Values are byte-transparent and written in their one spelling: plain when
they can be, text (`␂…␃`) when they hold a control byte, a line break or edge
whitespace. `C0.validate(buf)` checks a buffer against the grammar once
(raising a `C0::SyntaxError`); the navigators then assume well-formed input.

### Keyed records, nesting, references

```ruby
buf = C0.build do |b|
  b.group("server")
  b.map("host" => "0.0.0.0", "port" => "8080")   # ␞␁host␟0.0.0.0␁port␟8080
  b.record("Alice")
  b.list(%w[Admin Editor])                       # one unit: ␐␞Admin␟Editor␘
  b.level do                                     # ␐ … a whole body … ␘
    b.header(%w[street city])
    b.record("1 Main", "Springfield")
  end
  b.ref("tags")                                  # ␅tags
  b.ref("tags", "001", "label")                  # ␅␂tags␟001␟label␃
end

g = C0::Document.new(buf)["server"]
g.record(0).keyed?                 # => true
g.record(0)["port"]                # => "8080"  (last wins)
g.record(1).list(1)                # => ["Admin", "Editor"]
g.record(1).level(2).record(0)     # => the nested record
g.record(1).ref(4).path            # => ["tags", "001", "label"]
```

The builder also has `file`, `section`, `header`, `field`, `key` (with a
block for a nested value), `heading_level`, `note`, `block`, `item`,
`etb(payload)` and `em(tail)`, matching the Crystal reference; every method
returns the builder, so calls chain.

### Primitives

Underneath, the builder has one method per code: `fs`, `gs`, `rs`, `us`,
`sub` (C0-DIFF only), `soh`, `dle`, `can`, `bel`, `enq`, `syn`, `eot`,
`etb`, `em`. Each writes its code and, when given, what follows it, so a
chain reads like the bytes, and anything the grammar allows can be written.
The argument is optional where the grammar allows the bare code (`gs`, `rs`,
`us`, `sub`, `soh`, `bel`, `etb`); `enq` takes one name or a path of two or
three:

```ruby
b.rs("Alice").us("1502.30")                              # ␞Alice␟1502.30
b.rs.soh("host").us("localhost").soh("port").us("5432")  # ␞␁host␟localhost␁port␟5432
b.gs("users").soh.rs("name").us("amount")                # ␝users␁␞name␟amount: a header row
b.rs("cfg").us.dle.rs.soh("b").us("2").can               # ␞cfg␟␐␞␁b␟2␘: a nested level
b.bel("checked").rs("x")                                 # ␇checked␞x: a note
b.bel.gs("old")                                          # ␇␝old: a dead group
b.gs.gs("sub").rs.enq("users").us.enq("users", "1")      # ␝␝sub␞␅users␟␅␂users␟1␃
b.syn.soh("version").us("1").rs("a").eot                 # ␖␁version␟1␞a␄
b.rs("old").sub("new")                                   # ␞old␚new: a C0-DIFF replace-all
```

The composed methods above are built on these and cannot write ill-formed
output; with the primitives, well-formedness is yours. Values keep their one
spelling either way (there is no STX/ETX primitive), and names are still
checked. The two layers share the record state and mix freely:
`b.rs("a").field("b")` writes `␞a␟b`, `b.record.us("c")` writes `␞␟c`.

## Install / build

The C core and the shared conformance vectors are git submodules:

```sh
git submodule update --init   # pulls in c0-c (the header) and c0-spec
rake compile                  # builds the extension
```

Requires a C compiler and Ruby development headers (MRI).

## Status

Binds the c0-c 1.0 core: validator and canonical check, documents and
containers (SYN heading, EOT, EM tail, warnings), bodies with files, groups,
header rows, positional and keyed records, nested levels, lists and references
(all zero-copy), the canonical builder, ETB stream mode (committed region,
damaged blocks, torn-tail detection) and pretty form (compact, aligned and
spaced). Passes every shared conformance vector from
[c0-spec](https://github.com/c0data/c0-spec) (decode, encode, canonical,
invalid, nested, stream).

Converters (CSV / JSON / C0-DIFF) are not yet wrapped.

## Test

```sh
rake test
```

## License

MIT
