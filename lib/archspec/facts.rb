# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'
require 'yaml'

module ArchSpec
  # A versioned snapshot of externally established references and generated
  # methods. Producers may run application code; consumers only read data.
  module Facts
    extend self

    VERSION = 1
    DOCUMENT_KEYS = %w[version producer environment snapshot references methods gaps].freeze
    LOCATION_KEYS = %w[path line column end_line end_column source_path].freeze

    def snapshot(graph, excluding: 'archspec_facts')
      excluded = File.expand_path(excluding, graph.root)
      inputs = Dir.glob(File.join(graph.root, 'config/**/*.{rb,yml,yaml}')) +
               Dir.glob(File.join(graph.root, '{Gemfile,Gemfile.lock,*.gemspec,.ruby-version}'))
      (graph.files.keys + inputs).select { |path| File.file?(path) }
        .reject { |path| path == excluded || path.start_with?("#{excluded}/") }
        .uniq.sort.to_h do |path|
          [Pathname(path).relative_path_from(Pathname(graph.root)).to_s, Digest::SHA256.file(path).hexdigest]
        end
    end

    def load_into(graph, directory)
      paths = Dir.glob(File.join(File.expand_path(directory, graph.root), '*.yml')).sort
      raise Error, "no facts found in #{directory}; run `archspec reflect` or your facts producer" if paths.empty?

      current = snapshot(graph, excluding: directory)
      paths.each do |path|
        document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        validate_document(document, path, current)
        apply_document(graph, document, path)
      end
      graph.clear_method_caches
    rescue Psych::Exception, SystemCallError => error
      raise Error, "could not load facts: #{error.message}"
    end

    def write(path, document)
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create(['.archspec-facts-', '.yml'], File.dirname(path)) do |file|
        file.write(document.to_yaml)
        file.flush
        file.close
        File.rename(file.path, path)
      end
    rescue SystemCallError => error
      raise Error, "could not write facts #{path}: #{error.message}"
    end

    private

    def validate_document(document, path, current)
      unless document.is_a?(Hash) && document['version'] == VERSION &&
             (document.keys - DOCUMENT_KEYS).empty? &&
             document['producer'].is_a?(String) && !document['producer'].empty? &&
             (document['environment'].nil? || document['environment'].is_a?(String)) &&
             %w[references methods gaps].all? { |key| document[key].nil? || document[key].is_a?(Array) }
        raise Error, "invalid facts file #{path}: expected version #{VERSION}, a producer, and fact lists"
      end
      unless document['snapshot'] == current
        raise Error, "stale facts file #{path}: source or configuration changed; regenerate it with its producer"
      end
      environment = document['environment']
      if environment && ENV['RAILS_ENV'] && ENV['RAILS_ENV'] != environment
        raise Error, "facts file #{path} was captured for #{environment}, but RAILS_ENV is #{ENV['RAILS_ENV']}"
      end
    end

    def apply_document(graph, document, path)
      Array(document['references']).each do |entry|
        validate_entry(entry, %w[source target] + LOCATION_KEYS, path)
        location = location_for(graph, entry, path)
        source = source_for(graph, entry, 'source', path)
        target = constant_name(entry['target'], path)
        next if graph.edges.any? do |edge|
          edge.type == :references_constant && edge.from_constant == source.name &&
            edge.from_path == source.path && edge.location == location && graph.resolve_edge_constant(edge) == target
        end

        graph.add_edge(type: :references_constant, from_path: source.path, from_constant: source.name,
                       to: target, resolved_to: target, location: location)
      end
      Array(document['methods']).each do |entry|
        validate_entry(entry, %w[owner scope names] + LOCATION_KEYS, path)
        location = location_for(graph, entry, path)
        owner = source_for(graph, entry, 'owner', path)
        scope = entry['scope']
        names = entry['names']
        unless %w[instance class].include?(scope) && names.is_a?(Array) && !names.empty? &&
               names.all? { |name| name.is_a?(String) && !name.empty? }
          raise Error, "invalid methods in facts file #{path}: expected scope and method names"
        end
        names.each do |name|
          next if owner.method_definitions.any? { |method| method.name == name.to_sym && method.scope == scope.to_sym }

          adder = scope == 'class' ? :add_class_method : :add_instance_method
          owner.public_send(adder, name, location: location)
        end
      end
      Array(document['gaps']).each do |entry|
        validate_entry(entry, %w[source message] + LOCATION_KEYS, path)
        location = location_for(graph, entry, path)
        source = source_for(graph, entry, 'source', path)
        unless entry['message'].is_a?(String) && !entry['message'].empty?
          raise Error, "invalid gap in facts file #{path}: expected a message"
        end
        graph.add_edge(type: :dynamic_feature, from_path: source.path, from_constant: source.name,
                       to: entry['message'], location: location, confidence: :unknown_due_to_dynamic_feature)
      end
    end

    def validate_entry(entry, keys, path)
      return if entry.is_a?(Hash) && (entry.keys - keys).empty?

      raise Error, "invalid entry in facts file #{path}"
    end

    def source_for(graph, entry, key, path)
      name = constant_name(entry[key], path)
      source_path = project_path(graph, entry['source_path'] || entry['path'], path)
      source = graph.constants_named(name).find { |node| node.path == source_path }
      raise Error, "invalid facts file #{path}: #{name} is not defined in #{entry['source_path'] || entry['path']}" unless source

      source
    end

    def constant_name(value, path)
      unless value.is_a?(String) && /\A(?:::)?[[:upper:]][[:alnum:]_]*(?:::[[:upper:]][[:alnum:]_]*)*\z/.match?(value)
        raise Error, "invalid constant name in facts file #{path}"
      end
      value.delete_prefix('::')
    end

    def project_path(graph, value, path)
      unless value.is_a?(String) && !Pathname(value).absolute?
        raise Error, "invalid source path in facts file #{path}"
      end
      expanded = File.expand_path(value, graph.root)
      unless expanded.start_with?("#{graph.root}/") && graph.files.key?(expanded)
        raise Error, "invalid facts file #{path}: source path #{value} is not analyzed"
      end
      expanded
    end

    def location_for(graph, entry, path)
      source = project_path(graph, entry['path'], path)
      line = entry['line']
      column = entry.fetch('column', 1)
      end_line = entry.fetch('end_line', line)
      end_column = entry.fetch('end_column', column)
      lines = File.readlines(source)
      valid = [line, column, end_line, end_column].all? { |value| value.is_a?(Integer) && value.positive? }
      valid &&= line <= lines.size && end_line <= lines.size &&
                ([line, column] <=> [end_line, end_column]) <= 0 &&
                column <= lines[line - 1].chomp.bytesize + 1 && end_column <= lines[end_line - 1].chomp.bytesize + 1
      raise Error, "invalid source location in facts file #{path}" unless valid

      SourceLocation.new(source, line, column, end_line, end_column)
    end
  end
end
