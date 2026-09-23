# c0

A Ruby implementation of [C0DATA](https://github.com/c0data) — structured data
built on ASCII C0 control codes.

This is **not** a reimplementation: it's a thin, fast binding over the
[c0 C core](https://github.com/c0data/c0-c) (a Ruby C extension, no runtime
dependencies), so the scan-heavy work runs as native C while the Ruby layer
provides an idiomatic API. The read path is **zero-copy** — field accessors
return shared byteslices into the input buffer.

## Usage

```ruby
require "c0"

# Write
buf = C0.build do |b|
  b.group("users", %w[name amount])
  b.record("Alice", "100")
  b.record("Bob", "200")
end

# Read (zero-copy: fields are shared byteslices of buf)
t = C0::Table.new(buf)
t.each do |rec|
  name, amount = rec.fields   # Array of byte strings
  rec.value(0)                # bytes, DLE-escapes decoded
end

# Compact form is canonical — hashable for content addressing
C0.canonical?(buf)            # => true

# Documents, streams, pretty
C0::Document.new(buf)
C0::StreamReader.new(File.binread("claims.c0"))   # #torn?, #committed, #blocks
C0.pretty_format(buf)                             # Unicode Control Pictures
```

### List fields

A field whose value is a flat list is written as US-separated items inside
STX/ETX (`␂Admin␟Editor␃`). `list_field` writes one; `Record#list` reads it
back as unescaped items.

```ruby
buf = C0.build do |b|
  b.group("users")
  b.record("Alice")
  b.list_field(%w[Admin Editor])   # one field: ␂Admin␟Editor␃
end
rec = C0::Table.new(buf).record(0)
rec.list(1)                        # => ["Admin", "Editor"]
```

The builder also has `field`, `nested`, `ref`, `section`, `block`, `item`,
and `etb(payload)`, matching the Crystal reference.

## Install / build

The C core and the shared conformance vectors are git submodules:

```sh
git submodule update --init   # pulls in c0-c (the header) and c0-spec
rake compile                  # builds the extension
```

Requires a C compiler and Ruby development headers (MRI).

## Status

Binds the c0-c core: tokenizer, table/record and document/group readers
(zero-copy), canonical helpers, ETB stream mode, and pretty
(`pretty_format`/`pretty_parse`). The builder is pure Ruby (byte-identical to the
C builder). Passes the shared conformance vectors from
[c0-spec](https://github.com/c0data/c0-spec).

Converters (CSV / JSON / C0DIFF) are not yet wrapped.

## Test

```sh
rake test
```

## License

MIT
