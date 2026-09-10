# frozen_string_literal: true

require 'test_helper'
require 'active_record'
require 'stringio'

class RailsReflectorTest < ArchSpecTest
  def teardown
    Object.send(:remove_const, :ReflectionFixture) if Object.const_defined?(:ReflectionFixture)
    super
  end

  def test_real_reflection_resolves_namespaces_overrides_and_polymorphic_gaps
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base
          end
          class Invoice < ActiveRecord::Base
            belongs_to :client, class_name: 'ReflectionFixture::Customer'
            belongs_to :attachable, polymorphic: true
          end
          class SpecialInvoice < Invoice
          end
        end
      RUBY
      load path
      graph = analyze(root)
      document = ArchSpec::RailsReflector.capture(graph,
        models: [ReflectionFixture::Invoice, ReflectionFixture::SpecialInvoice], environment: 'test')
      assert_equal [['ReflectionFixture::Invoice', 'ReflectionFixture::Customer']],
                   document['references'].map { |entry| entry.values_at('source', 'target') }
      assert_equal 5, document['references'].first['line']
      assert_equal ['polymorphic association ReflectionFixture::Invoice.attachable'], document['gaps'].map { |gap| gap['message'] }
      assert_equal [%w[attachable attachable=], %w[client client=]], document['methods'].map { |entry| entry['names'] }
      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", document)
      definition = ArchSpec.define do
        component :invoices, constants: 'ReflectionFixture::Invoice'
        component :customers, constants: 'ReflectionFixture::Customer'
        invoices.cannot_use :customers
        facts
      end
      diagnostics = diagnostics_for(definition, root)
      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule)
      assert_equal 'ReflectionFixture::Invoice references ReflectionFixture::Customer', diagnostics.first.evidence
    end
  end

  def test_associations_in_concern_callbacks_are_attributed_to_the_model
    with_project do |root|
      write "#{root}/app/models/concerns/owned.rb", <<~RUBY
        module ReflectionFixture
          module Owned
            extend ActiveSupport::Concern
            included do
              belongs_to :customer, class_name: 'ReflectionFixture::Customer'
            end
          end
        end
      RUBY
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Invoice < ActiveRecord::Base
            include Owned
          end
        end
      RUBY
      load "#{root}/app/models/concerns/owned.rb"
      load "#{root}/app/models/records.rb"
      document = ArchSpec::RailsReflector.capture(analyze(root), models: [ReflectionFixture::Invoice], environment: 'test')
      assert_empty document['gaps']
      assert_equal 'ReflectionFixture::Invoice', document['references'].first['source']
      assert_equal 5, document['references'].first['line']
      assert_equal 'app/models/concerns/owned.rb', document['references'].first['path']
      assert_equal 'app/models/records.rb', document['references'].first['source_path']
      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", document)
      definition = ArchSpec.define do
        component :invoices, constants: 'ReflectionFixture::Invoice'
        component :customers, constants: 'ReflectionFixture::Customer'
        invoices.cannot_use :customers
        facts
      end
      assert_equal ['dependencies.forbid'], diagnostics_for(definition, root).map(&:rule)
    end
  end

  def test_ambiguous_and_dynamic_declarations_are_reported_without_guessing
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Invoice < ActiveRecord::Base
            belongs_to :client, class_name: 'ReflectionFixture::Customer'
            belongs_to :client, class_name: 'ReflectionFixture::Customer'
            association_name = :customer
            belongs_to association_name, class_name: 'ReflectionFixture::Customer'
          end
        end
      RUBY
      capture_io { load path }
      document = ArchSpec::RailsReflector.capture(analyze(root), models: [ReflectionFixture::Invoice], environment: 'test')
      assert_empty document['references']
      assert_equal 2, document['gaps'].size
      assert document['gaps'].all? { |gap| gap['message'].include?('no unique literal declaration') }
    end
  end

  def test_through_associations_use_the_resolved_target
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Membership < ActiveRecord::Base
            belongs_to :customer
          end
          class Account < ActiveRecord::Base
            has_many :memberships
            has_many :customers, through: :memberships
          end
        end
      RUBY
      load path
      document = ArchSpec::RailsReflector.capture(analyze(root), models: [ReflectionFixture::Account], environment: 'test')
      assert_empty document['gaps']
      assert_equal %w[ReflectionFixture::Customer ReflectionFixture::Membership], document['references'].map { |entry| entry['target'] }
    end
  end

  def test_reflect_command_runs_an_explicit_subprocess_and_preserves_facts_on_failure
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\nfacts\n"
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Invoice < ActiveRecord::Base
            belongs_to :customer
          end
        end
      RUBY
      # A small runner harness isolates the process boundary while using real
      # Active Record models and the packaged reflection entrypoint.
      write "#{root}/bin/rails", <<~RUBY
        require 'active_record'
        abort 'wrong runner arguments' unless ARGV.take(3) == ['runner', '-e', 'test']
        module Rails
          def self.env = 'test'
          def self.application = self
          def self.eager_load!
            Dir['app/models/**/*.rb'].sort.each { |path| load path }
          end
        end
        load ARGV.last
      RUBY
      output = StringIO.new
      error = StringIO.new
      argv = ['reflect', '--config', "#{root}/Archspec.rb", '--environment', 'test']
      assert_equal 0, ArchSpec::CLI.run(argv, output: output, error: error), error.string
      assert_match(/1 association references/, output.string)
      path = "#{root}/archspec_facts/rails.yml"
      previous = File.read(path)
      write "#{root}/bin/rails", "warn 'boot failed'; exit 1\n"
      assert_equal 1, ArchSpec::CLI.run(argv, output: StringIO.new, error: error)
      assert_match(/boot failed/, error.string)
      assert_equal previous, File.read(path)
    end
  end

  def test_unresolved_through_associations_are_gaps
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Invoice < ActiveRecord::Base
            has_many :customers, through: :missing_association
          end
        end
      RUBY
      load path
      document = ArchSpec::RailsReflector.capture(analyze(root), models: [ReflectionFixture::Invoice], environment: 'test')
      assert_empty document['references']
      assert_equal 1, document['gaps'].size
      assert_match(/unresolved association/, document['gaps'].first['message'])
    end
  end

  private

  def analyze(root)
    definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
    ArchSpec::Analyzer.analyze(definition, root: root)
  end
end
