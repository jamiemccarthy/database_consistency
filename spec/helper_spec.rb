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

  describe '#conditions_where_sql' do
    # The conditions proc may chain order/limit/offset/group/having after
    # the where clause. These trailing clauses must not be included in the
    # extracted predicate, because they are not part of the row-subset
    # definition and will never appear in an index's WHERE.
    before do
      define_database_with_entity do |table|
        table.string :state
        table.string :name
      end
    end

    let(:model) { define_class }

    it 'extracts the WHERE clause with no trailing clauses' do
      expect(described_class.conditions_where_sql(model, -> { where(state: 'draft') }))
        .to eq("state = 'draft'")
    end

    it 'excludes ORDER BY from the predicate' do
      with_order = described_class.conditions_where_sql(model, -> { where(state: 'draft').order(:id) })
      without_order = described_class.conditions_where_sql(model, -> { where(state: 'draft') })
      expect(with_order).to eq(without_order)
    end

    it 'excludes LIMIT from the predicate' do
      with_limit = described_class.conditions_where_sql(model, -> { where(state: 'draft').limit(1) })
      without_limit = described_class.conditions_where_sql(model, -> { where(state: 'draft') })
      expect(with_limit).to eq(without_limit)
    end

    it 'excludes OFFSET from the predicate' do
      with_offset = described_class.conditions_where_sql(model, -> { where(state: 'draft').offset(5) })
      without_offset = described_class.conditions_where_sql(model, -> { where(state: 'draft') })
      expect(with_offset).to eq(without_offset)
    end

    it 'excludes GROUP BY from the predicate' do
      with_group = described_class.conditions_where_sql(model, -> { where(state: 'draft').group(:name) })
      without_group = described_class.conditions_where_sql(model, -> { where(state: 'draft') })
      expect(with_group).to eq(without_group)
    end

    it 'excludes GROUP BY and HAVING from the predicate' do
      with_having = described_class.conditions_where_sql(
        model, -> { where(state: 'draft').group(:name).having('COUNT(*) > 0') }
      )
      without_having = described_class.conditions_where_sql(model, -> { where(state: 'draft') })
      expect(with_having).to eq(without_having)
    end

    it 'excludes all trailing clauses combined' do
      combined = described_class.conditions_where_sql(
        model, -> { where(state: 'draft').order(:id).limit(1).offset(5).group(:name) }
      )
      plain = described_class.conditions_where_sql(model, -> { where(state: 'draft') })
      expect(combined).to eq(plain)
    end
  end
end
