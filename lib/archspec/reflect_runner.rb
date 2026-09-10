# frozen_string_literal: true

# Executed only by the explicit `archspec reflect` Rails runner subprocess.
require_relative '../archspec'

begin
  unless defined?(Rails.application) && Rails.application && defined?(ActiveRecord::Base)
    raise ArchSpec::Error, 'Rails reflection requires a loaded Rails application with Active Record'
  end
  Rails.application.eager_load!
  definition, root = ArchSpec::CLI.send(:load_definition, ENV.fetch('ARCHSPEC_REFLECTION_CONFIG'))
  graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
  if graph.files.values.any? { |file| file.parse_errors.any? }
    raise ArchSpec::Error, 'cannot reflect source with syntax errors'
  end
  document = ArchSpec::RailsReflector.capture(graph, models: ActiveRecord::Base.descendants,
    environment: Rails.env.to_s, facts_path: definition.facts_path)
  output = ENV.fetch('ARCHSPEC_REFLECTION_OUTPUT')
  ArchSpec::Facts.write(output, document)
  puts "Updated #{Pathname(output).relative_path_from(Pathname(root))} with #{document['references'].size} association references."
  document['gaps'].each { |gap| puts "Analysis gap: #{gap['message']}" }
rescue ArchSpec::Error => error
  warn error.message
  exit 1
end
