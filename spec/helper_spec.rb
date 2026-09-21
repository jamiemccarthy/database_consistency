# frozen_string_literal: true

RSpec.describe DatabaseConsistency::Helper, :sqlite, :mysql, :postgresql do
  describe '#first_level_associations' do
    subject { described_class.first_level_associations(child) }

    let(:parent) { define_class('Dummy') { |klass| klass.has_one :user } }

    context 'when only parent defines association' do
      let(:child) { stub_const('SubDummy', Class.new(parent)) }
      it { is_expected.to eq([]) }
    end

    context 'when child redefines association' do
      let(:child) { stub_const('SubDummy', Class.new(parent) { |klass| klass.has_one :user }) }
      it { expect(subject.size).to eq(1) }
    end
  end

  describe '#parent_models' do
    subject(:parent_models) { described_class.parent_models(DatabaseConsistency::Configuration.new) }

    before do
      allow(described_class).to receive(:project_klass?).and_return(true)

      define_database_with_entity { |table| table.string :email }

      define_class('Entities', :entities)
      define_class('Scoped::Entities', :entities)
      stub_const('SubEntities', Class.new(Entities))

      expect(ActiveRecord::Base)
        .to receive(:descendants)
        .and_return([Entities, Scoped::Entities, SubEntities])
    end

    it 'includes top-level classes only' do
      expect(subject).to include(Entities, Scoped::Entities)
      expect(subject).not_to include(SubEntities)
    end
  end

  describe '#project_klass', focus: true do
    subject(:project_klass) { described_class.project_klass?(klass) }

    # `Module.const_source_location` was added in Ruby-2.7, so on previous Ruby versions we always
    #   return `true` instead of `false` expected for this testcases
    context 'when the class is anonymous' do
      let(:klass) { define_class.tap { |k| k.singleton_class.remove_method(:name) } }

      context 'without a name' do
        it { is_expected.to be(RUBY_VERSION < '2.7') }
      end

      context 'with bogus name' do
        before { klass.define_singleton_method(:name) { 'Some invalid !@#' } }

        it { is_expected.to be(RUBY_VERSION < '2.7') }
      end
    end
  end

  describe '#models' do
    subject(:models) { described_class.models(DatabaseConsistency::Configuration.new) }

    before do
      allow(described_class).to receive(:project_klass?).and_return(true)

      define_database_with_entity { |table| table.string :email }

      define_class('Entities', :entities)
      define_class('Scoped::Entities', :entities)
      stub_const('SubEntities', Class.new(Entities))

      dummy_cache = Object.new
      dummy_cache.define_singleton_method(:data_source_exists?) { |_table_name| false }
      dummy_cache.define_singleton_method(:table_exists?) { |_table_name| false }

      dummy_connection = ActiveRecord::ConnectionAdapters::AbstractAdapter.new(nil)
      dummy_connection.define_singleton_method(:schema_cache) { dummy_cache }

      define_class('AbstractEntity') do |klass|
        klass.table_name = 'bogus'
        klass.define_singleton_method(:connection) { dummy_connection }
      end

      allow(ActiveRecord::Base)
        .to receive(:descendants)
        .and_return([Entities, Scoped::Entities, SubEntities, AbstractEntity])
    end

    specify do
      expect(models).to contain_exactly(Entities, Scoped::Entities, SubEntities)
    end
  end

  describe '#normalize_condition_sql' do
    context 'with string literals that contain metacharacters' do
      it 'does not unwrap parentheses inside a string literal' do
        expect(described_class.normalize_condition_sql("state = '(draft)'"))
          .to eq("state = '(draft)'")
      end

      it 'does not strip casts inside a string literal' do
        expect(described_class.normalize_condition_sql("label = 'a::text'"))
          .to eq("label = 'a::text'")
      end

      it 'preserves AND inside a string literal' do
        expect(described_class.normalize_condition_sql("name = 'foo AND bar'"))
          .to eq("name = 'foo AND bar'")
      end

      it 'preserves a literal containing AND while sorting real AND clauses' do
        expect(described_class.normalize_condition_sql("name = 'foo AND bar' AND b = 1"))
          .to eq("b = 1 AND name = 'foo AND bar'")
      end

      it 'does not unwrap parentheses around a value that looks like a column' do
        expect(described_class.normalize_condition_sql("code = '(none)'"))
          .to eq("code = '(none)'")
      end

      it 'preserves escaped single quotes inside literals' do
        # validator conditions: -> { where(value: "it's") }
        expect(described_class.normalize_condition_sql("value = 'it''s'")).to include("'it''s'")
      end

      it 'keeps the inequality operator inside a literal' do
        expect(described_class.normalize_condition_sql("note = 'a <> b'"))
          .to eq("note = 'a <> b'")
      end

      it 'does not normalize TRUE or FALSE inside a string literal' do
        # validator conditions: -> { where(label: 'TRUE') }
        expect(described_class.normalize_condition_sql("label = 'TRUE'")).to eq("label = 'TRUE'")
        expect(described_class.normalize_condition_sql("label = 'false'")).to eq("label = 'false'")
      end

      it 'does not collapse whitespace inside a string literal' do
        expect(described_class.normalize_condition_sql("label = 'foo  bar'"))
          .to eq("label = 'foo  bar'")
      end

      it 'strips outer parentheses even when a literal contains an unmatched parenthesis' do
        expect(described_class.normalize_condition_sql("(label = 'foo)bar')"))
          .to eq("label = 'foo)bar'")
      end

      it 'preserves an escaped inner boolean literal' do
        # validator conditions: -> { where(label: "x = 't'") }
        # index     where: "label = 'x = ''t'''"; PostgreSQL writes the value back unchanged
        expect(described_class.normalize_condition_sql("label = 'x = ''t'''"))
          .to eq("label = 'x = ''t'''")
      end
    end

    context 'with boolean predicate forms' do
      it "normalizes PostgreSQL 't'/'f' literals with flexible whitespace" do
        expect(described_class.normalize_condition_sql("flag='t'")).to eq('flag = 1')
        expect(described_class.normalize_condition_sql("flag  =   'f'")).to eq('flag = 0')
      end

      it "normalizes inequality comparisons to 't'/'f' without collapsing equality" do
        expect(described_class.normalize_condition_sql("flag <> 't'")).to eq('flag != 1')
        expect(described_class.normalize_condition_sql("flag != 'f'")).to eq('flag != 0')
        expect(described_class.normalize_condition_sql("flag = 'f'")).to eq('flag = 0')
      end

      it 'normalizes IS TRUE and IS FALSE' do
        expect(described_class.normalize_condition_sql('flag IS TRUE')).to eq('flag = 1')
        expect(described_class.normalize_condition_sql('flag IS FALSE')).to eq('flag = 0')
      end

      it "normalizes = TRUE and = 't' to the same comparison as IS TRUE" do
        # validator conditions: -> { where(flag: true) }
        expect(described_class.normalize_condition_sql('flag = TRUE')).to eq('flag = 1')
        # PostgreSQL deparses an index written as `flag = 't'` back to
        # `flag = true`, so the quoted spelling reaches here from a
        # hand-written condition rather than from a database.
        expect(described_class.normalize_condition_sql("flag = 't'")).to eq('flag = 1')
      end

      it 'normalizes TRUE = TRUE to 1 = 1' do
        expect(described_class.normalize_condition_sql('TRUE = TRUE')).to eq('1 = 1')
      end

      it 'normalizes IS NOT TRUE and IS NOT FALSE' do
        expect(described_class.normalize_condition_sql('flag IS NOT TRUE')).to eq('flag IS NOT 1')
        expect(described_class.normalize_condition_sql('flag IS NOT FALSE')).to eq('flag IS NOT 0')
      end

      it 'normalizes boolean predicate forms on parenthesized columns' do
        expect(described_class.normalize_condition_sql("(flag) = 't'")).to eq('flag = 1')
        expect(described_class.normalize_condition_sql('(flag) IS TRUE')).to eq('flag = 1')
        expect(described_class.normalize_condition_sql('(flag) IS NOT TRUE')).to eq('flag IS NOT 1')
      end

      it 'preserves boolean keywords inside string literals' do
        expect(described_class.normalize_condition_sql("label = 'IS TRUE'")).to eq("label = 'IS TRUE'")
      end

      # PostgreSQL writes a boolean comparison with the keyword, as `flag >= true`,
      # so a comparison against the one-character string is an ordering predicate
      # on a text column and keeps both its operator and its value.
      it "leaves an ordering comparison against 't' or 'f' alone" do
        # index     where: "note >= 't'" on a text column
        expect(described_class.normalize_condition_sql("(note >= 't'::text)")).to eq("note >= 't'")
        # index     where: "note <= 'f'"
        expect(described_class.normalize_condition_sql("(note <= 'f'::text)")).to eq("note <= 'f'")
        # index     where: "note > 'f' AND note < 't'"
        expect(described_class.normalize_condition_sql("((note > 'f'::text) AND (note < 't'::text))"))
          .to eq("note < 't' AND note > 'f'")
      end
    end

    context 'when identifiers are quoted' do
      it 'strips double-quoted identifiers' do
        # validator conditions: -> { where(state: 'draft') } on PostgreSQL or SQLite
        expect(described_class.normalize_condition_sql("\"state\" = 'draft'")).to eq("state = 'draft'")
      end

      it 'strips backtick-quoted identifiers' do
        # validator conditions: -> { where(state: 'draft') } on MySQL
        expect(described_class.normalize_condition_sql("`state` = 'draft'")).to eq("state = 'draft'")
      end
    end

    context 'with parenthesized numeric literals' do
      it 'unwraps a parenthesized integer literal with a cast' do
        # index     where: 'price > 0' on a numeric column
        expect(described_class.normalize_condition_sql('price > (0)::numeric')).to eq('price > 0')
      end

      it 'leaves the numeric argument of a function call alone' do
        # index     where: 'qty = abs(1)' on an integer column
        expect(described_class.normalize_condition_sql('(qty = abs(1))')).to eq('qty = abs(1)')
        # validator conditions: -> { where('qty = abs(1)') }
        expect(described_class.normalize_condition_sql('qty = abs(1)')).to eq('qty = abs(1)')
        # index     where: 'amount = trunc(1.5)' on a numeric column
        expect(described_class.normalize_condition_sql('(amount = trunc(1.5))')).to eq('amount = trunc(1.5)')
      end

      # A numeric column makes PostgreSQL cast the result of the call, and the
      # parentheses it groups the call in outlive the cast.
      it 'matches a function call against the cast PostgreSQL wraps it in' do
        # index     where: 'amount = abs(1)' on a numeric column
        expect(described_class.normalize_condition_sql('(amount = (abs(1))::numeric)')).to eq('amount = abs(1)')
        # validator conditions: -> { where('amount = abs(1)') }
        expect(described_class.normalize_condition_sql('amount = abs(1)')).to eq('amount = abs(1)')
      end

      it 'unwraps a parenthesized decimal literal with a cast' do
        expect(described_class.normalize_condition_sql('price > (0.0)::float8')).to eq('price > 0.0')
      end

      it 'unwraps a parenthesized small decimal literal' do
        # index     where: 'ratio > 0.00001' on a double precision column
        expect(described_class.normalize_condition_sql('price > (0.00001)::double precision')).to eq('price > 0.00001')
      end

      it 'unwraps a parenthesized large integer literal with a cast' do
        # index     where: 'price > 1000000' on a numeric column
        expect(described_class.normalize_condition_sql('price > (1000000)::numeric')).to eq('price > 1000000')
      end

      it 'unwraps a parenthesized decimal through nested casts' do
        expect(described_class.normalize_condition_sql('price > ((1.23)::real)::numeric')).to eq('price > 1.23')
      end

      it 'unwraps a decimal through three levels of nested casts' do
        expect(described_class.normalize_condition_sql('price > (((1.23)::real)::numeric)::double precision'))
          .to eq('price > 1.23')
      end

      it 'does not unwrap parentheses around a number-string literal' do
        # validator conditions: -> { where(code: '(0)') }
        expect(described_class.normalize_condition_sql("code = '(0)'")).to eq("code = '(0)'")
      end
    end

    context 'with multi-word and array casts' do
      it 'strips a double precision cast' do
        expect(described_class.normalize_condition_sql('price > (0.0)::double precision')).to eq('price > 0.0')
      end

      it 'strips a character varying cast' do
        # index     the spelling PostgreSQL gives a varchar value inside ARRAY[...];
        # a bare comparison comes back as `(label)::text = 'x'::text`
        expect(described_class.normalize_condition_sql("label = 'x'::character varying")).to eq("label = 'x'")
      end

      it 'strips a timestamp without time zone cast' do
        # index     where: "created_at > '2024-01-01'" on a timestamp column
        expect(described_class.normalize_condition_sql("created_at > '2024-01-01'::timestamp without time zone"))
          .to eq("created_at > '2024-01-01'")
      end

      it 'strips a time cast with and without a time zone' do
        # index     where: "opens_at > '10:00:00'" on a time column
        expect(described_class.normalize_condition_sql("(opens_at > '10:00:00'::time without time zone)"))
          .to eq("opens_at > '10:00:00'")
        # validator conditions: -> { where("opens_at > '10:00:00'") }
        expect(described_class.normalize_condition_sql("opens_at > '10:00:00'")).to eq("opens_at > '10:00:00'")
        # index     where: "opens_at > '10:00:00+00'" on a timetz column
        expect(described_class.normalize_condition_sql("(opens_at > '10:00:00+00'::time with time zone)"))
          .to eq("opens_at > '10:00:00+00'")
      end

      it 'strips a bit varying cast' do
        # index     where: "mask = '101'" on a bit varying column
        expect(described_class.normalize_condition_sql("(mask = '101'::bit varying)")).to eq("mask = '101'")
      end

      it 'strips a cast that carries a length' do
        # index     where: "nm::char(3) = 'ab'"
        expect(described_class.normalize_condition_sql("((nm)::character(3) = 'ab'::bpchar)"))
          .to eq("nm = 'ab'")
        # index     where: "nm::varchar(3) = 'ab'"
        expect(described_class.normalize_condition_sql("(((nm)::character varying(3))::text = 'ab'::text)"))
          .to eq("nm = 'ab'")
        # validator conditions: -> { where("nm::varchar(3) = 'ab'") }
        expect(described_class.normalize_condition_sql("nm::varchar(3) = 'ab'")).to eq("nm = 'ab'")
        # index     where: 'amount::numeric(5,2) > 0'
        expect(described_class.normalize_condition_sql('((amount)::numeric(5,2) > (0)::numeric)'))
          .to eq('amount > 0')
      end

      # A date or time type carries its precision inside its name rather than
      # after it, so the cast reads `::timestamp(0) without time zone`. Only a
      # narrowing cast survives: PostgreSQL drops one that cannot change the
      # value, which is why the column here is declared wider than the cast.
      it 'strips a date or time cast that carries a precision' do
        # index     where: "ts::timestamp(0) > '2024-01-01'" on a timestamp(6) column
        expect(described_class.normalize_condition_sql(
                 "((ts)::timestamp(0) without time zone > '2024-01-01 00:00:00'::timestamp without time zone)"
               )).to eq("ts > '2024-01-01 00:00:00'")
        # validator conditions: -> { where("ts::timestamp(0) > '2024-01-01 00:00:00'") }
        expect(described_class.normalize_condition_sql("ts::timestamp(0) > '2024-01-01 00:00:00'"))
          .to eq("ts > '2024-01-01 00:00:00'")
        # index     where: "tstz::timestamptz(0) > '2024-01-01'" on a timestamptz(6) column
        expect(described_class.normalize_condition_sql(
                 "((tstz)::timestamp(0) with time zone > '2024-01-01 00:00:00+00'::timestamp with time zone)"
               )).to eq("tstz > '2024-01-01 00:00:00+00'")
        # index     where: "tm::time(0) > '10:00'" on a time(6) column
        expect(described_class.normalize_condition_sql(
                 "((tm)::time(0) without time zone > '10:00:00'::time without time zone)"
               )).to eq("tm > '10:00:00'")
        # index     where: "tmtz::timetz(0) > '10:00+00'" on a timetz(6) column
        expect(described_class.normalize_condition_sql(
                 "((tmtz)::time(0) with time zone > '10:00:00+00'::time with time zone)"
               )).to eq("tmtz > '10:00:00+00'")
      end

      it 'strips an array cast and normalizes ANY (ARRAY[...]) to IN (...)' do
        expect(described_class.normalize_condition_sql("state = ANY (ARRAY['draft'::character varying]::text[])"))
          .to eq("state IN ('draft')")
      end

      it 'normalizes a simple ANY (ARRAY[...]) with one text element' do
        expect(described_class.normalize_condition_sql("state = ANY (ARRAY['draft'])")).to eq("state IN ('draft')")
      end

      it 'normalizes a simple ANY (ARRAY[...]) with multiple text elements' do
        expect(described_class.normalize_condition_sql("state = ANY (ARRAY['draft', 'published'])"))
          .to eq("state IN ('draft', 'published')")
      end

      it 'normalizes ANY (ARRAY[...]) with a cast element' do
        expect(described_class.normalize_condition_sql("state = ANY (ARRAY['draft'::text])"))
          .to eq("state IN ('draft')")
      end

      it 'normalizes ANY (ARRAY[...]) with numeric elements' do
        expect(described_class.normalize_condition_sql('price = ANY (ARRAY[1, 2, 3])')).to eq('price IN (1, 2, 3)')
      end

      it 'normalizes ANY (ARRAY[...]) with float elements' do
        expect(described_class.normalize_condition_sql('price = ANY (ARRAY[1.5, 2.5])')).to eq('price IN (1.5, 2.5)')
      end

      it 'normalizes a Postgres indexdef-style ANY array wrapped in extra parentheses' do
        # index     where: "state IN ('draft','canon')" on a varchar column
        expect(described_class.normalize_condition_sql(
                 "((state)::text = ANY ((ARRAY['draft'::character varying, " \
                 "'canon'::character varying])::text[]))"
               ))
          .to eq("state IN ('draft', 'canon')")
      end

      it 'keeps the parentheses of an IN list' do
        # validator conditions: -> { where(state: %w[draft published]) }
        expect(described_class.normalize_condition_sql("(state IN ('draft', 'published'))"))
          .to eq("state IN ('draft', 'published')")
      end

      # The parentheses around `ARRAY[...]` are optional but always come as a
      # pair, so a group enclosing the whole predicate keeps its own.
      it 'leaves an enclosing group intact around an IN list' do
        expect(described_class.normalize_condition_sql('((qty = ANY (ARRAY[1, 2])) AND (a = 1))'))
          .to eq('a = 1 AND qty IN (1, 2)')
      end

      it 'leaves it intact when the array carries the optional pair as well' do
        expect(described_class.normalize_condition_sql(
                 "(((state)::text = ANY ((ARRAY['x'::character varying])::text[])) AND (qty > 0))"
               ))
          .to eq("qty > 0 AND state IN ('x')")
      end

      it 'leaves an enclosing group intact around a NOT IN list' do
        expect(described_class.normalize_condition_sql("(((state)::text <> ALL (ARRAY['x'::text])) AND (qty > 0))"))
          .to eq("qty > 0 AND state NOT IN ('x')")
      end

      # PostgreSQL deparses `NOT IN` as `<> ALL (ARRAY[...])`, the mirror of the
      # `= ANY (ARRAY[...])` it deparses `IN` into. `where.not(col: [...])` is
      # what generates it.
      it 'normalizes ALL (ARRAY[...]) to NOT IN (...)' do
        expect(described_class.normalize_condition_sql("state <> ALL (ARRAY['x', 'y'])"))
          .to eq("state NOT IN ('x', 'y')")
      end

      it 'normalizes ALL (ARRAY[...]) with one element' do
        expect(described_class.normalize_condition_sql("state <> ALL (ARRAY['x'])"))
          .to eq("state NOT IN ('x')")
      end

      it 'normalizes ALL (ARRAY[...]) with numeric elements' do
        expect(described_class.normalize_condition_sql('qty <> ALL (ARRAY[1, 2])'))
          .to eq('qty NOT IN (1, 2)')
      end

      it 'normalizes an ALL array whose elements carry a cast' do
        expect(described_class.normalize_condition_sql("((state)::text <> ALL (ARRAY['x'::text, 'y'::text]))"))
          .to eq("state NOT IN ('x', 'y')")
      end

      it 'normalizes a Postgres indexdef-style ALL array wrapped in extra parentheses' do
        # index     where: "state NOT IN ('x','y')" on a varchar column
        expect(described_class.normalize_condition_sql(
                 "((state)::text <> ALL ((ARRAY['x'::character varying, " \
                 "'y'::character varying])::text[]))"
               ))
          .to eq("state NOT IN ('x', 'y')")
      end

      it 'leaves the NOT IN Active Record generates unchanged' do
        # validator conditions: -> { where.not(state: %w[x y]) }
        expect(described_class.normalize_condition_sql("state NOT IN ('x', 'y')"))
          .to eq("state NOT IN ('x', 'y')")
      end

      # Only `= ANY` and `!= ALL` carry the meaning of `IN` and `NOT IN`; the
      # other two pairings mean something else and keep their own spelling.
      it 'rewrites ANY and ALL only for the operator that matches them' do
        # index     where: "state <> ANY (ARRAY['a','b'])"
        expect(described_class.normalize_condition_sql("(state <> ANY (ARRAY['a'::text, 'b'::text]))"))
          .to eq("state != ANY (ARRAY['a', 'b'])")
        # index     where: "state = ALL (ARRAY['a','b'])"
        expect(described_class.normalize_condition_sql("(state = ALL (ARRAY['a'::text, 'b'::text]))"))
          .to eq("state = ALL (ARRAY['a', 'b'])")
      end
    end

    # PostgreSQL quotes every negative and every exponent literal, and the only
    # thing separating one from a string is the cast: `::integer`, `::bigint`,
    # `::numeric` or `::double precision` for a number, `::text` for a string.
    # A number loses its quotes so it lines up with the bare one Active Record
    # writes; a string keeps them.
    context 'with negative and exponent numeric literals' do
      it 'leaves a quoted value carrying a text cast alone' do
        # index     where: "code = '-1'" on a varchar column
        expect(described_class.normalize_condition_sql("((code)::text = '-1'::text)")).to eq("code = '-1'")
        # validator conditions: -> { where(code: '-1') }
        expect(described_class.normalize_condition_sql("code = '-1'")).to eq("code = '-1'")
      end

      it 'leaves a quoted exponent carrying a text cast alone' do
        expect(described_class.normalize_condition_sql("((code)::text = '1e+20'::text)")).to eq("code = '1e+20'")
      end

      it 'leaves the elements of a string array alone' do
        expect(described_class.normalize_condition_sql("((code)::text = ANY (ARRAY['-1'::text, '2'::text]))"))
          .to eq("code IN ('-1', '2')")
      end

      it 'keeps every digit of a wide numeric literal' do
        # index     where: 'amount > 1000000000000000000000000000000'
        expect(described_class.normalize_condition_sql("(amount > '1000000000000000000000000000000'::numeric)"))
          .to eq('amount > 1000000000000000000000000000000')
      end

      it 'unquotes a bigint literal' do
        # index     where: 'b > 3000000000' and 'b > -3000000000' on a bigint column
        expect(described_class.normalize_condition_sql("(b > '3000000000'::bigint)")).to eq('b > 3000000000')
        expect(described_class.normalize_condition_sql("(b > '-3000000000'::bigint)")).to eq('b > -3000000000')
      end

      it 'unquotes a positive literal that Postgres had to coerce' do
        # index     where: 'amount > 100000000000000000000' on a numeric column
        expect(described_class.normalize_condition_sql("(amount > '100000000000000000000'::numeric)"))
          .to eq('amount > 100000000000000000000')
      end

      it 'unquotes only the numeric side of a mixed predicate' do
        expect(
          described_class.normalize_condition_sql(
            # index     where: "code = '-1' AND amount > -1", varchar and numeric columns
            "(((code)::text = '-1'::text) AND (amount > ('-1'::integer)::numeric))"
          )
        ).to eq("amount > -1 AND code = '-1'")
      end

      it 'leaves a string literal that merely contains a cast alone' do
        # index     where: "code = '-1::numeric'" on a varchar column
        expect(described_class.normalize_condition_sql("((code)::text = '-1::numeric'::text)"))
          .to eq("code = '-1::numeric'")
      end

      it 'keeps a negative operand parenthesized where precedence needs it' do
        # index     where: 'qty % -3 = 0' on an integer column
        expect(described_class.normalize_condition_sql("((qty % '-3'::integer) = 0)")).to eq('(qty % -3) = 0')
      end

      it 'unquotes a negative integer' do
        # index     where: 'qty > -1' on an integer column
        expect(described_class.normalize_condition_sql("(qty > '-1'::integer)")).to eq('qty > -1')
      end

      it 'unquotes a negative integer widened by a nested numeric cast' do
        # index     where: 'amount > -1' on a numeric column: the literal is coerced
        # to integer first, then widened to the column's type
        expect(described_class.normalize_condition_sql("(amount > ('-1'::integer)::numeric)")).to eq('amount > -1')
      end

      it 'unquotes a negative decimal' do
        # index     where: 'amount > -1.5' on a numeric column
        expect(described_class.normalize_condition_sql("(amount > '-1.5'::numeric)")).to eq('amount > -1.5')
      end

      it 'unquotes a negative float through its numeric cast' do
        # index     where: 'ratio > -1.5' on a double precision column
        expect(described_class.normalize_condition_sql("(ratio > ('-1.5'::numeric)::double precision)"))
          .to eq('ratio > -1.5')
      end

      it 'unquotes a negative element inside an ARRAY' do
        # index     where: 'qty IN (-1, 2)' on an integer column
        expect(described_class.normalize_condition_sql("(qty = ANY (ARRAY['-1'::integer, 2]))"))
          .to eq('qty IN (-1, 2)')
      end

      it 'expands an exponent literal to the decimal Postgres writes' do
        # index     where: "ratio > '1e+20'::double precision". A quoted literal keeps
        # its exponent; PostgreSQL expands a bare `1e+20` itself before storing it.
        expect(described_class.normalize_condition_sql("(ratio > '1e+20'::double precision)"))
          .to eq('ratio > 100000000000000000000')
        expect(described_class.normalize_condition_sql("(ratio > '1e-20'::double precision)"))
          .to eq('ratio > 0.00000000000000000001')
      end

      it 'expands a negative exponent with a fractional mantissa' do
        # index     where: "ratio > '-1.5e-25'::double precision"
        expect(described_class.normalize_condition_sql("(ratio > '-1.5e-25'::double precision)"))
          .to eq('ratio > -0.00000000000000000000000015')
      end

      # Active Record writes a float with an explicit `.0` mantissa.
      it 'expands the exponent Active Record writes to the same digits' do
        # validator conditions: -> { where('ratio > ?', 1e20) }
        expect(described_class.normalize_condition_sql('ratio > 1.0e+20')).to eq('ratio > 100000000000000000000')
        expect(described_class.normalize_condition_sql('ratio > 1.0e-20')).to eq('ratio > 0.00000000000000000001')
      end

      it 'leaves a decimal Postgres has already expanded alone' do
        # index     where: 'amount > 1e-20' on a numeric column
        expect(described_class.normalize_condition_sql('(amount > 0.00000000000000000001)'))
          .to eq('amount > 0.00000000000000000001')
      end

      it 'expands an exponent element inside an ARRAY' do
        expect(
          described_class.normalize_condition_sql(
            # index     where: "ratio IN ('1e+20'::double precision, 2)"
            "(ratio = ANY (ARRAY['1e+20'::double precision, (2)::double precision]))"
          )
        ).to eq('ratio IN (100000000000000000000, 2)')
      end

      it 'does not expand digits that belong to an identifier' do
        # validator conditions: -> { where(a1e5: 1) }, a column whose name ends in digits
        expect(described_class.normalize_condition_sql('a1e5 = 1')).to eq('a1e5 = 1')
      end

      # PostgreSQL expands an exponent before it stores the predicate, so this
      # mantissa only ever reaches here from a hand-written condition. It still
      # has to land on the digits the index side writes.
      it 'expands a mantissa written below one to the same digits' do
        # validator conditions: -> { where('ratio > 0.1e+2') }; index where: 'ratio > 10'
        expect(described_class.normalize_condition_sql('ratio > 0.1e+2')).to eq('ratio > 10')
        # validator conditions: -> { where('ratio > 0.1e+21') }; index where: 'ratio > 1e+20'
        expect(described_class.normalize_condition_sql('ratio > 0.1e+21'))
          .to eq('ratio > 100000000000000000000')
      end

      it 'keeps a zero that carries the value' do
        # validator conditions: -> { where('ratio > 0e+0') }; index where: 'ratio > 0'
        expect(described_class.normalize_condition_sql('ratio > 0e+0')).to eq('ratio > 0')
        # validator conditions: -> { where('ratio > 0.5e+0') }; index where: 'ratio > 0.5'
        expect(described_class.normalize_condition_sql('ratio > 0.5e+0')).to eq('ratio > 0.5')
      end
    end

    context 'with real-world partial-index predicates' do
      it 'strips outer parens when a literal has unmatched parens and normalizes booleans' do
        expect(described_class.normalize_condition_sql("((label = 'Region (North)') AND active = TRUE)"))
          .to eq("active = 1 AND label = 'Region (North)'")
      end
    end
  end
end
