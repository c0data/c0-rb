# frozen_string_literal: true

module C0
  # The heading of a document: the keyed units after SYN. Last wins for a
  # duplicate key. Enumerates [key, value] pairs.
  class Heading
    include Enumerable

    KNOWN_KEYS = %w[shape version blob].freeze

    def initialize(buf, start, stop)
      @buf = buf
      @start = start
      @stop = stop
    end

    # [key, value] in written order: the logical value, or for a nested level
    # (the blob table) its raw bytes.
    def pairs
      @pairs ||= raw_pairs.map do |k, s, e|
        [k, Ext.unit_type(@buf, s, e) == UnitType::LEVEL ? @buf.byteslice(s, e - s) : Ext.value(@buf, s, e)]
      end
    end

    def each(&) = pairs.each(&)

    def keys = raw_pairs.map(&:first)

    # Value for a key (last wins), or nil.
    def [](key)
      needle = C0.to_bin(key)
      found = nil
      pairs.each { |k, v| found = v if k == needle }
      found
    end

    def key?(key) = !self[key].nil?

    def empty? = raw_pairs.empty?

    # The `shape` value as a String, or nil.
    def shape = self["shape"]&.dup&.force_encoding(Encoding::UTF_8)

    # The `version` value as an Integer; 1 when absent or not a number.
    def version
      v = self["version"]
      v && v.match?(/\A\d+\z/) ? v.to_i : 1
    end

    # The value under a key as a nested level, or nil when absent or not one.
    def level(key)
      range = raw_range(key)
      return nil unless range && Ext.unit_type(@buf, *range) == UnitType::LEVEL

      ls, le = Ext.unit_level(@buf, *range)
      Body.new(@buf, ls, le)
    end

    # The blob table as a Body, when declared as a level.
    def blob = level("blob")

    # The heading's bytes.
    def raw = @buf.byteslice(@start, @stop - @start)

    private

    def raw_pairs
      @raw_pairs ||= Ext.record_pairs(@buf, @start, @stop).map { |ks, ke, vs, ve| [@buf.byteslice(ks, ke - ks), vs, ve] }
    end

    def raw_range(key)
      needle = C0.to_bin(key)
      found = nil
      raw_pairs.each { |k, s, e| found = [s, e] if k == needle }
      found
    end
  end

  # One C0DATA document: an optional SYN heading, a body, an optional EOT.
  # `Document.new(buf)` reads the first document in the buffer. Use
  # `Container` for a buffer holding several documents or an EM tail.
  # Enumerates the groups of the body's first file.
  class Document
    include Enumerable

    SHAPES = %w[diff stream tabular document key-value].freeze

    attr_reader :buf, :heading, :body, :start, :stop

    def initialize(buf, start = 0)
      @buf = C0.to_bin(buf)
      load(Ext.document(@buf, start))
    end

    # A document from the C reader's description (see Container).
    def self.from_ext(buf, desc)
      doc = allocate
      doc.instance_variable_set(:@buf, buf)
      doc.send(:load, desc)
      doc
    end

    def has_syn? = @has_syn

    alias syn? has_syn?

    def has_eot? = @has_eot

    alias eot? has_eot?

    # Loud warnings (DESIGN.md "Warnings") as strings; empty for a careful writer's file.
    def warnings
      @warnings ||= begin
        w = []
        w << "no SYN at the start of the document" unless @has_syn
        w << "no EOT at the end of the document" if !@has_eot && heading.shape != "stream"
        heading.keys.each do |k|
          w << "unknown heading key '#{k}'" unless Heading::KNOWN_KEYS.include?(k)
        end
        seen = {}
        heading.keys.each { |k| w << "duplicate heading key '#{k}'" if seen.key?(k) && !w.include?("duplicate heading key '#{k}'"); seen[k] = true }
        if (sh = heading.shape) && !SHAPES.include?(sh)
          w << "unknown shape '#{sh}'"
        end
        if (v = heading["version"]) && v != "1".b
          w << "unknown version '#{v}'"
        end
        w
      end
    end

    # ---- convenience accessors over the body --------------------------------

    def name = @body.name

    def files = @body.files

    def group_count = @body.group_count

    def group(index_or_name) = @body.group(index_or_name)

    alias [] group

    def each_group(&) = @body.each_group(&)

    alias each each_group

    def groups = @body.groups

    def group_names = @body.group_names

    def records = @body.records

    def shape = heading.shape

    # The document's bytes (SYN through EOT).
    def raw = @buf.byteslice(@start, @stop - @start)

    private

    def load(desc)
      @start, @stop, @has_syn, @has_eot, hs, he, bs, be, _bits = desc
      @heading = Heading.new(@buf, hs, he)
      @body = Body.new(@buf, bs, be)
    end
  end

  # A file or message: one or more documents and an optional raw tail after
  # EM. Enumerates the documents.
  class Container
    include Enumerable

    attr_reader :buf, :documents, :tail

    def initialize(buf)
      @buf = C0.to_bin(buf)
      descs, @has_em, em_pos = Ext.documents(@buf)
      @documents = descs.map { |d| Document.from_ext(@buf, d) }
      @tail = @has_em ? @buf.byteslice(em_pos + 1, @buf.bytesize - em_pos - 1) : "".b
    end

    def has_em? = @has_em

    alias em? has_em?

    def each(&) = @documents.each(&)

    def first = @documents[0]

    def size = @documents.size

    # Loud warnings about the container as a whole; each document carries its own.
    def warnings
      @warnings ||= begin
        w = []
        @documents.each_with_index do |doc, i|
          next unless doc.heading.key?("blob")

          if i.positive?
            w << "blob table in a later heading is ignored"
          elsif doc.heading.blob.nil?
            w << "blob is not a level: declares nothing"
          elsif !doc.heading.blob.groups.first&.header?
            w << "blob table has no header row: declares nothing"
          end
        end
        w << "EM with no blob table: the region is unaddressable" if @has_em && blob_table.nil?
        w
      end
    end

    # The blob table from the first document's heading, as a Body, or nil.
    def blob_table = first&.heading&.blob

    # Bytes of a named blob from the tail (columns matched by header name,
    # last row wins), or nil. With no name, the blob table itself.
    def blob(name = nil)
      return blob_table if name.nil?

      table = blob_table or return nil
      g = table.groups.first or return nil
      ni = g.column("name") || 0
      oi = g.column("offset") || 1
      li = g.column("length") || 2
      needle = C0.to_bin(name)
      found = nil
      g.records.each do |r|
        next unless r.value(ni) == needle

        off = r.value(oi)
        len = r.value(li)
        next unless off&.match?(/\A\d+\z/) && len&.match?(/\A\d+\z/)

        off = off.to_i
        len = len.to_i
        next if off > @tail.bytesize || len > @tail.bytesize - off

        found = @tail.byteslice(off, len)
      end
      found
    end
  end
end
