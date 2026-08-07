require "yaml"

module Fluxion::Config
  # A YAML value together with the dotted path that reached it.
  #
  # Every diagnostic Fluxion prints names the exact config location that caused
  # it (`spec.phases[1].steps[0].spec.packageManager`), which is only possible
  # if the path travels with the value. Walking the document by hand rather
  # than deserializing into DTOs is what buys that, plus the freedom to accept
  # the several shapes the schema allows for one field.
  #
  # A missing key produces a node rather than nil, so a chain like
  # `node["spec"]["target"]["os"]` never needs intermediate nil checks and
  # still reports the full path when the leaf turns out to be required.
  struct Node
    getter path : String
    getter raw : YAML::Any?

    def initialize(@raw : YAML::Any?, @path : String = "")
    end

    def self.root(document : YAML::Any) : self
      new(document, "")
    end

    # An absent node. Distinct from a node holding YAML `null`, which counts as
    # present-but-empty for the same purposes.
    def missing? : Bool
      @raw.nil?
    end

    def null? : Bool
      raw = @raw
      raw.nil? || raw.raw.nil?
    end

    def present? : Bool
      !null?
    end

    def mapping? : Bool
      @raw.try(&.as_h?) != nil
    end

    def sequence? : Bool
      @raw.try(&.as_a?) != nil
    end

    def scalar? : Bool
      present? && !mapping? && !sequence?
    end

    # Child lookup. Accepts the first key that is present, so schema aliases
    # read as `node["shell", "shellPath"]` and report the canonical name.
    def [](*keys : String) : Node
      mapping = @raw.try(&.as_h?)
      return Node.new(nil, child_path(keys.first)) unless mapping

      keys.each do |key|
        # One lookup rather than `has_key?` followed by `[]`: both wrap the key
        # in a `YAML::Any` and hash it, and this runs for every field of every
        # step. A key whose value is YAML `null` still returns a node here,
        # which is the distinction `missing?` and `null?` exist to preserve.
        if value = mapping[YAML::Any.new(key)]?
          return Node.new(value, child_path(key))
        end
      end
      Node.new(nil, child_path(keys.first))
    end

    def has_key?(key : String) : Bool
      mapping = @raw.try(&.as_h?)
      return false unless mapping
      mapping.has_key?(YAML::Any.new(key))
    end

    # Keys in document order, so diagnostics and generated output follow what
    # the user actually wrote.
    def keys : Array(String)
      mapping = @raw.try(&.as_h?)
      return [] of String unless mapping
      mapping.keys.compact_map(&.as_s?)
    end

    def each_entry(& : String, Node ->) : Nil
      mapping = @raw.try(&.as_h?)
      return unless mapping
      mapping.each do |key, value|
        name = key.as_s?
        next unless name
        yield name, Node.new(value, child_path(name))
      end
    end

    # Sequence elements, each carrying an indexed path. A non-sequence yields
    # nothing; callers that want to complain about the shape check `sequence?`.
    def items : Array(Node)
      sequence = @raw.try(&.as_a?)
      return [] of Node unless sequence
      sequence.map_with_index { |value, index| Node.new(value, "#{@path}[#{index}]") }
    end

    def each_item(& : Node, Int32 ->) : Nil
      items.each_with_index { |node, index| yield node, index }
    end

    # Scalar as a string, whatever its YAML type. A release written as `44`
    # rather than `"44"` should not be a different field.
    def string? : String?
      raw = @raw
      return unless raw
      case value = raw.raw
      when String then value
      when Int64  then value.to_s
      when Float64
        # An unquoted version like 8.14 parses as a float; render it back
        # without the trailing zero YAML round-tripping would add.
        value == value.trunc ? value.to_i64.to_s : value.to_s
      when Bool then value.to_s
      end
    end

    def bool? : Bool?
      raw = @raw
      return unless raw
      case value = raw.raw
      when Bool then value
      when String
        case value.strip.downcase
        when "true", "yes", "on"  then true
        when "false", "no", "off" then false
        end
      end
    end

    def int? : Int32?
      raw = @raw
      return unless raw
      case value = raw.raw
      when Int64  then value.to_i32
      when String then value.strip.to_i32?
      end
    end

    # Sequence of strings, tolerating a bare scalar as a one-element list —
    # `commands: git status` and `commands: [git status]` mean the same thing.
    def string_list : Array(String)
      return items.compact_map(&.string?) if sequence?
      value = string?
      value ? [value] : [] of String
    end

    # String-to-string mapping, used by `entries`, `locale`, and `vars`.
    def string_map : Hash(String, String)
      result = {} of String => String
      each_entry do |key, value|
        text = value.string?
        result[key] = text if text
      end
      result
    end

    private def child_path(key : String) : String
      return key if @path.empty?
      # Keys that are not plain identifiers are bracketed so the path stays
      # unambiguous when a profile uses a dotted or hyphenated key.
      key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? "#{@path}.#{key}" : "#{@path}.['#{key}']"
    end
  end
end
