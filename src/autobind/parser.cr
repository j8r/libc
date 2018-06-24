require "clang"
require "compiler/crystal/formatter"

module Autobind
  class Parser
    protected getter index : Clang::Index
    protected getter translation_unit : Clang::TranslationUnit
    getter output = ""

    def libc_output
      "lib LibC\n#{@output}end\n"
    end

    def check
      Crystal.format libc_output
      true
    rescue ex
      "The generated binding results of invalid Crystal code:\n#{ex}"
    end

    @remove_enum_prefix : String | Bool
    @remove_enum_suffix : String | Bool

    enum Process
      EVERYTHING
      FILE
    end

    def self.parse(header_name, args = [] of String, process : Process = Process::FILE)
      new(header_name, args).parse
    end

    def initialize(@header_name : String, args = [] of String,
                   @process : Process = Process::FILE,
                   @remove_enum_prefix = false,
                   @remove_enum_suffix = false)
      # TODO: support C++ (rename input.c to input.cpp)
      # TODO: support local filename (use quotes instead of angle brackets)
      files = [
        Clang::UnsavedFile.new("input.c", "#include <#{@header_name}>\n"),
      ]
      options = Clang::TranslationUnit.default_options |
                Clang::TranslationUnit::Options.flags(DetailedPreprocessingRecord, SkipFunctionBodies)

      @index = Clang::Index.new
      @translation_unit = Clang::TranslationUnit.from_source(index, files, args, options)
    end

    def parse
      translation_unit.cursor.visit_children do |cursor|
        if @process.everything? || cursor.location.file_name.try(&.ends_with?("/#{@header_name}"))
          case cursor.kind
          when .macro_definition? then visit_define(cursor, translation_unit)
          when .typedef_decl?     then visit_typedef(cursor)
          when .enum_decl?        then visit_enum(cursor) unless cursor.spelling.empty?
          when .struct_decl?      then visit_struct(cursor) unless cursor.spelling.empty?
          when .union_decl?       then visit_union(cursor)
          when .function_decl?    then visit_function(cursor)
          when .var_decl?         then visit_var(cursor)
            # when .class_decl?
            # TODO: C++ classes
            # when .namespace_decl?
            # TODO: C++ namespaces
          when .macro_expansion?, .macro_instantiation?, .inclusion_directive?
            # skip
          else
            puts "WARNING: unexpected #{cursor.kind} child cursor"
          end
        end
        Clang::ChildVisitResult::Continue
      end
    end

    def visit_define(cursor, translation_unit)
      # TODO: analyze the tokens to build the constant value (e.g. type cast, ...)
      # TODO: parse the result String to verify it is valid Crystal

      value = String.build do |str|
        previous = nil
        translation_unit.tokenize(cursor.extent, skip: 1) do |token|
          case token.kind
          when .comment?
            next
          when .punctuation?
            break if token.spelling == "#"
          when .literal?
            parse_literal_token(token.spelling, str)
            previous = token
            next
          else
            str << ' ' if previous
          end
          str << token.spelling
          previous = token
        end
      end

      if value.starts_with?('(') && value.ends_with?(')')
        value = value[1..-2]
      end

      case value
      when /^[-+]?(UInt|Long|ULong|LongLong|ULongLong)\.new\([+-]?[e0-9a-fA-F]+\)$/,
           /^0x[e0-9a-fA-F]+$/,
           /^[+-]?[e0-9a-fA-F]+$/,
           /^[_A-Z][_A-Za-z0-9]+$/
        @output += "  #{cursor.spelling.lstrip('_')} = #{value}\n"
      else
        @output += "  # #{cursor.spelling} = #{value}\n"
      end
    end

    private def parse_literal_token(literal, io)
      if literal =~ /^((0[X])?([+\-0-9A-F.e]+))(F|L|U|UL|LL|ULL)?$/i
        number, prefix, digits, suffix = $1, $2?, $3, $4?

        if prefix == "0x" && suffix == "F" && digits.size.odd?
          # false-positive: matched 0xFF, 0xffff, ...
          io << literal
        else
          case suffix.try(&.upcase)
          when "U"
            io << "UInt.new(" << number << ")"
          when "L"
            if number.index('.')
              io << "LongDouble.new(" << number << ")"
            else
              io << "Long.new(" << number << ")"
            end
          when "F"   then io << number << "_f32"
          when "UL"  then io << "ULong.new(" << number << ")"
          when "LL"  then io << "LongLong.new(" << number << ")"
          when "ULL" then io << "ULongLong.new(" << number << ")"
          else            io << number
          end
        end
      else
        io << literal
      end
    end

    def visit_typedef(cursor)
      children = [] of Clang::Cursor

      cursor.visit_children do |c|
        children << c
        Clang::ChildVisitResult::Continue
      end

      if children.size <= 1
        type = cursor.typedef_decl_underlying_type

        if type.kind.elaborated?
          t = type.named_type
          c = t.cursor

          # did the typedef named the anonymous struct? in which case we do
          # process the struct now, or did the struct already have a name? in
          # which case we already processed it:
          return unless c.spelling.empty?

          case t.kind
          when .record?
            # visit_typedef_struct(cursor, type.named_type.cursor)
            visit_struct(c, cursor.spelling)
          when .enum?
            # visit_typedef_enum(cursor, type.named_type.cursor)
            visit_enum(c, cursor.spelling)
          else
            puts "  # WARNING: unexpected #{t.kind} within #{cursor.kind} (visit_typedef)"
          end
        else
          name = Constant.to_crystal(cursor.spelling)
          @output += "  alias #{name} = #{Type.to_crystal(type)}\n"
        end
      else
        visit_typedef_proc(cursor, children)
      end
    end

    # private def visit_typedef_struct(cursor, c)
    #  case c.spelling
    #  when .empty?
    #    visit_struct(c, cursor.spelling)
    #  when cursor.spelling
    #    # skip
    #  else
    #    name = Constant.to_crystal(cursor.spelling)
    #    type = Constant.to_crystal(c.spelling)
    #    puts "  alias #{name} = #{type}"
    #  end
    # end

    # private def visit_typedef_enum(cursor, c)
    #  case c.spelling
    #  when .empty?
    #    visit_enum(c, cursor.spelling)
    #  when cursor.spelling
    #    # skip
    #  else
    #    name = Constant.to_crystal(cursor.spelling)
    #    type = Type.to_crystal(c.type)
    #    puts "  alias #{name} = #{type}"
    #  end
    # end

    private def visit_typedef_type(cursor, c)
      name = Constant.to_crystal(cursor.spelling)
      type = Type.to_crystal(c.type.canonical_type)
      @output += "  alias #{name} = #{type}\n"
    end

    private def visit_typedef_proc(cursor, children)
      if children.first.kind.parm_decl?
        ret = "Void"
      else
        ret = Type.to_crystal(children.shift.type.canonical_type)
      end

      @output += "  alias #{Constant.to_crystal(cursor.spelling)} = ("
      children.each_with_index do |c, index|
        @output += ", " unless index == 0
        # unless c.spelling.empty?
        #  print c.spelling.underscore
        #  print " : "
        # end
        @output += Type.to_crystal(c.type).to_s
      end
      @output += ") -> #{ret}\n"
    end

    def visit_enum(cursor, spelling = cursor.spelling)
      type = cursor.enum_decl_integer_type.canonical_type
      @output += "  enum #{Constant.to_crystal(spelling)} : #{Type.to_crystal(type)}\n"

      values = [] of {String, Int64 | UInt64}

      cursor.visit_children do |c|
        case c.kind
        when .enum_constant_decl?
          value = case type.kind
                  when .u_int? then c.enum_constant_decl_unsigned_value
                  else              c.enum_constant_decl_value
                  end
          values << {c.spelling, value}
        else
          puts "    # WARNING: unexpected #{c.kind} within #{cursor.kind} (visit_enum)"
        end
        Clang::ChildVisitResult::Continue
      end

      prefix = cleanup_prefix_from_enum_constant(cursor, values)
      suffix = cleanup_suffix_from_enum_constant(cursor, values)

      values.each do |name, value|
        if name.includes?(spelling)
          # when the enum spelling is fully duplicated in constants: remove it all
          constant = name.delete(spelling).lstrip('_')
        else
          # remove similar prefix/suffix patterns from all constants:
          start = prefix.size
          stop = Math.max(suffix.size + 1, 1)
          constant = name[start..-stop]
        end

        unless constant[0].ascii_uppercase?
          constant = Constant.to_crystal(constant)
        end

        @output += "    #{constant} = #{value}\n"
      end

      @output += "  end\n"
    end

    private def cleanup_prefix_from_enum_constant(cursor, values)
      prefix = ""
      reference = values.size > 1 ? values.first[0] : cursor.spelling

      if pre = @remove_enum_prefix
        reference = pre if pre.is_a?(String)

        reference.each_char do |c|
          testing = prefix + c

          if values.all? &.first.starts_with?(testing)
            prefix = testing
          else
            # TODO: try to match a word delimitation, to only remove whole words
            #       not a few letters that happen to match.
            return prefix
          end
        end
      end

      prefix
    end

    private def cleanup_suffix_from_enum_constant(cursor, values)
      suffix = ""
      reference = values.size > 1 ? values.first[0] : cursor.spelling

      if suf = @remove_enum_suffix
        reference = suf if suf.is_a?(String)

        reference.reverse.each_char do |c|
          testing = c.to_s + suffix

          if values.all? &.first.ends_with?(testing)
            suffix = testing
          else
            # try to match a word delimitation, to only remove whole words not a
            # few letters that happen to match:
            a, b = suffix[0]?, suffix[1]?
            if a && b && (a == '_' || (a.ascii_uppercase? && !b.ascii_uppercase?))
              return suffix
            else
              return ""
            end
          end
        end
      end

      suffix
    end

    def visit_struct(cursor, spelling = cursor.spelling)
      members_count = 0

      definition = String.build do |str|
        str.puts "  struct #{Constant.to_crystal(spelling)}"

        cursor.visit_children do |c|
          members_count += 1

          case c.kind
          when .field_decl?
            str.puts "    #{c.spelling.underscore} : #{Type.to_crystal(c.type)}"
          when .struct_decl?
            if c.type.kind.record?
              # skip
            else
              p [:TODO, :inner_struct, c]
            end
          else
            str.puts "WARNING: unexpected #{c.kind} within #{cursor.kind} (visit_struct)"
          end
          Clang::ChildVisitResult::Continue
        end

        str.puts "  end"
      end

      if members_count == 0
        @output += "  type #{Constant.to_crystal(spelling)} = Void\n"
      else
        @output += definition + '\n'
      end
    end

    def visit_union(cursor)
      # p [:union, cursor.spelling]
      # TODO: visit_union
    end

    def visit_function(cursor)
      arguments = cursor.arguments

      @output += "  fun #{cursor.spelling}("
      cursor.arguments.each_with_index do |c, index|
        print ", " unless index == 0
        print Type.to_crystal(c.type) # .canonical_type
      end
      @output += ") : #{Type.to_crystal(cursor.result_type)}\n" # .canonical_type
    end

    def visit_var(cursor)
      type = Type.to_crystal(cursor.type.canonical_type)
      #    puts "  $#{cursor.spelling} : #{type}"
    end
  end
end
