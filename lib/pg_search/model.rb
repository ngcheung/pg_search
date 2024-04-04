# frozen_string_literal: true

module PgSearch
  module Model
    extend ActiveSupport::Concern

    module ClassMethods
      def pg_search_scope(name, options)
        options_proc = if options.respond_to?(:call)
                         options
                       elsif options.respond_to?(:merge)
                         ->(query) { { query: query }.merge(options) }
                       else
                         raise ArgumentError, 'pg_search_scope expects a Hash or Proc'
                       end

        define_singleton_method(name) do |*args|
          config = Configuration.new(options_proc.call(*args), self)
          scope_options = ScopeOptions.new(config)
          scope_options.apply(self)
        end
      end

      def multisearchable(options = {})
        include PgSearch::Multisearchable
        class_attribute :pg_search_multisearchable_options
        self.pg_search_multisearchable_options = options
      end

      def pg_search_column(name, options)
        class_attribute :pg_search_column, :pg_search_tsvector_scope
        self.pg_search_column = name

        scope_options = ScopeOptions.new(Configuration.new(options, self))
        feature = scope_options.send(:feature_for, :tsearch)
        computed_vector_sql = feature.send(:columns).map do |column|
          feature.send(:column_to_tsvector, column)
        end.join(' || ') + ' as _pg_search_vector'

        self.pg_search_tsvector_scope = unscoped
          .joins(scope_options.send(:subquery_join))
          .select(computed_vector_sql)

        after_save :update_pg_search_column
      end

      def reindex
        subquery = self.class.pg_search_tsvector_scope

        ActiveRecord::Base.connection.execute(
          <<-SQL.squish
            update #{self.class.table_name}
              set #{self.class.pg_search_column} = _pg_search_vector
              from (#{subquery.to_sql}) subquery
              where id = subquery.id
          SQL
        )
      end
    end

    def update_pg_search_column
      subquery = self.class.pg_search_tsvector_scope.where(id: id)

      ActiveRecord::Base.connection.execute(
        <<-SQL.squish
          update #{self.class.table_name}
            set #{self.class.pg_search_column} = _pg_search_vector
            from (#{subquery.to_sql}) subquery
            where id = #{id}
        SQL
      )
    end

    def method_missing(symbol, *args)
      case symbol
      when :pg_search_rank
        raise PgSearchRankNotSelected unless respond_to?(:pg_search_rank)

        read_attribute(:pg_search_rank).to_f
      when :pg_search_highlight
        raise PgSearchHighlightNotSelected unless respond_to?(:pg_search_highlight)

        read_attribute(:pg_search_highlight)
      else
        super
      end
    end

    def respond_to_missing?(symbol, *args)
      case symbol
      when :pg_search_rank
        attributes.key?(:pg_search_rank)
      when :pg_search_highlight
        attributes.key?(:pg_search_highlight)
      else
        super
      end
    end
  end
end
