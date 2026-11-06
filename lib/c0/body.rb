# frozen_string_literal: true

module C0
  # Zero-copy navigator for a document body: the bytes between a heading and
  # EOT, or the inside of a nested level. Everything it returns is a shared
  # byteslice of the original buffer.
  #
  # Records before the first GS of a file form an unnamed group; records and
  # groups before the first FS form an unnamed file. Enumerates the groups of
  # the first file.
  class Body
    include Enumerable

    attr_reader :buf, :start, :stop

    def initialize(buf, start = 0, stop = nil)
      @buf = C0.to_bin(buf)
      @start = start
      @stop = stop || @buf.bytesize
    end

    # The files, in order (at least one: the unnamed leading file).
    def files
      @files ||= Ext.files(@buf, @start, @stop).map { |ns, ne, s, e| FileView.new(@buf, ns, ne, s, e) }
    end

    # All groups of all files, in order.
    def groups
      @groups ||= Ext.groups(@buf, @start, @stop).map { |d, ns, ne, s, e| Group.new(@buf, d, ns, ne, s, e) }
    end

    # Groups of the first file.
    def group_count = first_file.groups.size

    # Group by index or by name (first file). Raises C0::KeyError for a name
    # with no group.
    def group(index_or_name)
      index_or_name.is_a?(Integer) ? first_file.groups[index_or_name] : first_file.group(index_or_name)
    end

    alias [] group

    def each_group(&) = first_file.groups.each(&)

    alias each each_group

    def group_names = first_file.groups.map(&:name)

    # Name of the first file (empty when the body has no FS).
    def name = first_file.name

    # Records of the body when it is a bare record stream (no FS, no GS): the
    # unnamed group's records.
    def records = first_file.groups.first&.records || []

    def record_count = records.size

    def record(index) = records[index]

    def each_record(&) = records.each(&)

    # Whether the body is just records: one unnamed file, at most the unnamed group.
    def bare? = Ext.body_bare(@buf, @start, @stop)

    # The body's bytes.
    def raw = @buf.byteslice(@start, @stop - @start)

    private

    def first_file = files[0]
  end

  # A file within a body: its name and groups. Enumerates the groups.
  class FileView
    include Enumerable

    attr_reader :start, :stop

    def initialize(buf, name_start, name_end, start, stop)
      @buf = buf
      @name_start = name_start
      @name_end = name_end
      @start = start
      @stop = stop
    end

    def name = @buf.byteslice(@name_start, @name_end - @name_start)

    def groups
      @groups ||= Ext.groups(@buf, @start, @stop).map { |d, ns, ne, s, e| Group.new(@buf, d, ns, ne, s, e) }
    end

    # The first group with this name. Raises C0::KeyError when there is none.
    def group(name)
      needle = C0.to_bin(name)
      groups.find { |g| g.name == needle } or raise KeyError, "No group named '#{name}'"
    end

    alias [] group

    def each(&) = groups.each(&)

    def raw = @buf.byteslice(@start, @stop - @start)
  end

  # A group: its depth (GS count; 0 for the unnamed leading group), name,
  # optional header row and records. Enumerates the records.
  class Group
    include Enumerable

    attr_reader :depth, :start, :stop

    def initialize(buf, depth, name_start, name_end, start, stop)
      @buf = buf
      @depth = depth
      @name_start = name_start
      @name_end = name_end
      @start = start
      @stop = stop
    end

    def name = @buf.byteslice(@name_start, @name_end - @name_start)

    # The header row as a Record, or nil.
    def header_row
      return @header_row if defined?(@header_row)

      range = Ext.group_header(@buf, @start, @stop)
      @header_row = range && Record.new(@buf, range[0], range[1])
    end

    def header? = !header_row.nil?

    alias has_header? header?

    # Header names, or an empty array.
    def headers = header_row ? header_row.values : []

    def header_count = header_row ? header_row.field_count : 0

    def header(index) = headers[index]

    # Index of a header name, or nil.
    def column(name)
      needle = C0.to_bin(name)
      headers.index(needle)
    end

    # The live records (header row, notes, commits and dead elements skipped).
    def records
      @records ||= Ext.group_records(@buf, @start, @stop).map { |s, e| Record.new(@buf, s, e) }
    end

    def record_count = records.size

    alias size record_count

    def record(index) = records[index]

    def each_record(&) = records.each(&)

    alias each each_record

    # The group as a table is itself.
    def table = self

    # The group's contents (after its name).
    def raw = @buf.byteslice(@start, @stop - @start)
  end

  Table = Group

  # A record: positional or keyed, never mixed. Zero-copy accessors.
  # Enumerates the logical values of a positional record.
  class Record
    include Enumerable

    attr_reader :start, :stop

    def initialize(buf, start, stop)
      @buf = buf
      @start = start
      @stop = stop
    end

    # The record's bytes (after its RS, trailing layout excluded).
    def raw = @buf.byteslice(@start, @stop - @start)

    # Whether the record is keyed (its first live unit is an SOH).
    def keyed? = Ext.record_keyed(@buf, @start, @stop)

    # ---- positional ---------------------------------------------------------

    # Raw bytes of unit n (its layout included), or of the unit under a key
    # (last wins); nil when there is none.
    def field(index_or_key)
      s, e = index_or_key.is_a?(Integer) ? units[index_or_key] : keyed_range(index_or_key)
      s && @buf.byteslice(s, e - s)
    end

    # Number of positional units (0 for a keyed record).
    def field_count = units.size

    alias size field_count

    def fields = units.map { |s, e| @buf.byteslice(s, e - s) }

    # Logical value of unit n, or nil when there is none.
    def value(index)
      s, e = units[index]
      s && Ext.value(@buf, s, e)
    end

    def values = units.map { |s, e| Ext.value(@buf, s, e) }

    def each(&) = values.each(&)

    # Unit n (or the unit under a key) as a nested level. Raises C0::Error when
    # it is not one; nil for a key with no unit.
    def level(index_or_key)
      s, e = index_or_key.is_a?(Integer) ? units[index_or_key] : keyed_range(index_or_key)
      return nil if s.nil? && !index_or_key.is_a?(Integer)
      raise KeyError, "no unit #{index_or_key}" if s.nil?

      ls, le = Ext.unit_level(@buf, s, e)
      Body.new(@buf, ls, le)
    end

    # Unit n as a flat list: a level holding at most one positional record.
    # Raises C0::Error for any other level.
    def list(index)
      s, e = units[index]
      raise KeyError, "no unit #{index}" if s.nil?

      Ext.unit_list(@buf, s, e).map { |is, ie| Ext.value(@buf, is, ie) }
    end

    # Unit n as a Reference.
    def ref(index)
      s, e = units[index]
      raise KeyError, "no unit #{index}" if s.nil?

      Reference.new(Ext.unit_ref(@buf, s, e).map { |rs, re| @buf.byteslice(rs, re - rs) })
    end

    # ---- keyed --------------------------------------------------------------

    # Keys in written order (duplicates included).
    def keys = pair_ranges.map { |ks, ke, _, _| @buf.byteslice(ks, ke - ks) }

    # [key, logical value] pairs in written order.
    def pairs = pair_ranges.map { |ks, ke, vs, ve| [@buf.byteslice(ks, ke - ks), Ext.value(@buf, vs, ve)] }

    # Logical value under a key (last wins), or nil.
    def [](key)
      s, e = keyed_range(key)
      s && Ext.value(@buf, s, e)
    end

    def key?(key) = !keyed_range(key).nil?

    alias has_key? key?

    # The keyed record as a Hash (last wins).
    def to_h = pairs.to_h

    private

    def units = @units ||= Ext.record_units(@buf, @start, @stop)

    def pair_ranges = @pair_ranges ||= Ext.record_pairs(@buf, @start, @stop)

    def keyed_range(key)
      needle = C0.to_bin(key)
      found = nil
      pair_ranges.each do |ks, ke, vs, ve|
        found = [vs, ve] if @buf.byteslice(ks, ke - ks) == needle
      end
      found
    end
  end

  # A reference: a group name, or a path of two or three segments
  # (group, record id, field name).
  class Reference
    attr_reader :path

    def initialize(path)
      @path = path
    end

    # Parse a raw unit (ENQ …). Raises C0::Error when it is not a reference.
    def self.parse(raw)
      b = C0.to_bin(raw)
      new(Ext.unit_ref(b, 0, b.bytesize).map { |s, e| b.byteslice(s, e - s) })
    end

    def group = @path[0]

    def record = @path[1]

    def field = @path[2]

    def group? = @path.size == 1

    def ==(other) = other.is_a?(Reference) && other.path == @path

    alias eql? ==

    def hash = @path.hash

    def to_s = @path.join("/")
  end
end
