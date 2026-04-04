require 'set'
require_relative 'descriptor_registry/type_mapping'
require_relative 'descriptor_registry/dependency_resolver'
require_relative 'descriptor_registry/proto_builder'
require_relative 'descriptor_registry/file_descriptor_indexer'
require_relative 'descriptor_registry/object_space_indexer'

module GrpcServerReflection
  class DescriptorRegistry
    attr_reader :service_names

    def initialize(services: nil, allowed_service_names: nil)
      @files_by_symbol = {}       # symbol => filename
      @serialized_files = {}      # filename => serialized bytes
      @dependencies = {}          # filename => [dep_filename, ...]
      @service_names = Set.new
      @extensions_by_type = {}
      @allowed_services = if allowed_service_names
                            allowed_service_names
                          elsif services
                            services.map { |s| s.service_name }.compact
                          end

      build_index
    end

    def list_services
      @service_names.to_a
    end

    def find_file_by_name(filename)
      @serialized_files[filename]
    end

    def find_filename_by_symbol(symbol)
      @files_by_symbol[symbol]
    end

    def find_file_by_symbol(symbol)
      filename = @files_by_symbol[symbol]
      return nil unless filename
      @serialized_files[filename]
    end

    def file_descriptors_with_dependencies(filename)
      return [] unless @serialized_files.key?(filename)

      visited = Set.new
      result = []
      collect_dependencies(filename, visited, result)
      result
    end

    def find_extension_numbers(type)
      @extensions_by_type.fetch(type, [])
    end

    private

    def build_index
      pool = Google::Protobuf::DescriptorPool.generated_pool

      index_data = {
        files_by_symbol: @files_by_symbol,
        serialized_files: @serialized_files,
        dependencies: @dependencies,
        service_names: @service_names,
      }

      if pool.respond_to?(:each_file_descriptor)
        FileDescriptorIndexer.new(allowed_services: @allowed_services).build_index(pool, **index_data)
      else
        ObjectSpaceIndexer.new(allowed_services: @allowed_services).build_index(**index_data)
      end
    end

    def collect_dependencies(filename, visited, result)
      return if visited.include?(filename)
      visited << filename

      serialized = @serialized_files[filename]
      return unless serialized

      result << serialized

      deps = @dependencies[filename]
      if deps
        deps.each { |dep| collect_dependencies(dep, visited, result) }
      end
    end
  end
end
