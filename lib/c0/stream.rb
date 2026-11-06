# frozen_string_literal: true

module C0
  # Stream mode: ETB-committed append logs (DESIGN.md "Stream Mode").
  #
  #   r = C0::Stream::Reader.new(File.binread("events.c0"))
  #   r.torn?           # => data trails the last commit
  #   r.each_record { |rec| ... }
  module Stream
    # Scans a buffer for commits. An unescaped ETB is always a commit, even
    # inside open text or a level; such a block is damaged and yields nothing.
    # The tail after the last commit is torn unless it holds only layout,
    # notes, EOT or EM. Enumerates the committed blocks' bytes.
    class Reader
      include Enumerable

      attr_reader :buf, :committed_end

      def initialize(buf)
        @buf = C0.to_bin(buf)
        @committed_end, @torn, @blocks = Ext.stream(@buf)
      end

      def self.read(path) = new(File.binread(path))

      def torn? = @torn

      # The bytes up to and including the last commit.
      def committed = @buf.byteslice(0, @committed_end)

      # The bytes after the last commit.
      def tail = @buf.byteslice(@committed_end, @buf.bytesize - @committed_end)

      def block_count = @blocks.size

      alias size block_count

      # Block i's bytes (previous commit to ETB, marker and payload excluded).
      def block(index)
        s, e, = @blocks[index]
        s && @buf.byteslice(s, e - s)
      end

      def blocks = @blocks.map { |s, e, _| @buf.byteslice(s, e - s) }

      def each_block(&) = blocks.each(&)

      alias each each_block

      # Indexes of the damaged blocks (cut by an ETB inside open text or a level).
      def damaged = @blocks.each_index.select { |i| @blocks[i][2] }

      def damaged?(index) = @blocks[index] ? @blocks[index][2] : false

      # The committed region as a document, undamaged blocks only.
      def document = Document.new(Ext.stream_undamaged(@buf))

      def body = document.body

      # The committed records as a group (the first group, or an empty one).
      def table
        b = body
        b.groups.first || Group.new("".b, 0, 0, 0, 0, 0)
      end

      # Every committed record, across all groups.
      def records = body.groups.flat_map(&:records)

      def each_record(&) = records.each(&)
    end

    # Position just past the last commit, found by a backward scan: a
    # shortcut for well-formed input (Reader is authoritative).
    def self.last_commit_end(buf) = Ext.last_commit_end(C0.to_bin(buf))
  end
end
