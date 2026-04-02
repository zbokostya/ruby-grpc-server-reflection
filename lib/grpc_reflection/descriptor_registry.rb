module GrpcReflection
  class DescriptorRegistry
    attr_reader :service_names

    def initialize
      @files_by_name = {}
      @files_by_symbol = {}
      @service_names = []
      @extensions_by_type = {}

      build_index
    end

    def list_services
      @service_names
    end

    def find_file_by_name(filename)
      @files_by_name[filename]
    end

    def find_file_by_symbol(symbol)
      @files_by_symbol[symbol]
    end

    def file_descriptors_with_dependencies(filename)
      return [] unless @files_by_name.key?(filename)

      visited = {}
      collect_dependencies(filename, visited)
      visited.values
    end

    def find_extension_numbers(type)
      @extensions_by_type.fetch(type, [])
    end

    private

    def build_index
      pool = Google::Protobuf::DescriptorPool.generated_pool

      if pool.respond_to?(:each_file_descriptor)
        build_index_from_file_descriptors(pool)
      else
        build_index_from_object_space
      end
    end

    def build_index_from_file_descriptors(pool)
      pool.each_file_descriptor do |fd|
        serialized = fd.to_proto
        name = fd.name

        @files_by_name[name] = serialized

        index_services(fd, serialized)
        index_messages(fd, serialized)
        index_enums(fd, serialized)
      end
    end

    def build_index_from_object_space
      index_grpc_services
      index_file_descriptors
    end

    def index_grpc_services
      ObjectSpace.each_object(Class).each do |klass|
        next unless safe_respond_to?(klass, :service_name)
        next unless klass.included_modules.include?(GRPC::GenericService)

        service_name = klass.service_name
        next if service_name.nil? || service_name.empty?

        @service_names << service_name

        # Try to find the file descriptor via RPC method input types
        if klass.respond_to?(:rpc_descs)
          klass.rpc_descs.each_value do |desc|
            input_type = desc.input
            if safe_respond_to?(input_type, :descriptor) && input_type.descriptor.respond_to?(:file_descriptor)
              fd = input_type.descriptor.file_descriptor
              if fd
                @files_by_symbol[service_name] = fd
                break
              end
            end
          end
        end
      end
    end

    def index_file_descriptors
      ObjectSpace.each_object(Google::Protobuf::FileDescriptor).each do |fd|
        @files_by_name[fd.name] = fd
      end

      index_symbols_from_object_space
    end

    def index_symbols_from_object_space
      ObjectSpace.each_object(Class).each do |klass|
        next unless safe_respond_to?(klass, :descriptor)
        next unless klass.descriptor.is_a?(Google::Protobuf::Descriptor)

        desc = klass.descriptor
        fd = desc.file_descriptor
        next unless fd

        @files_by_name[fd.name] = fd unless @files_by_name.key?(fd.name)
        @files_by_symbol[desc.name] = fd
      end
    end

    def safe_respond_to?(obj, method)
      obj.respond_to?(method)
    rescue StandardError
      false
    end

    def collect_dependencies(filename, visited)
      return if visited.key?(filename)

      entry = @files_by_name[filename]
      return unless entry

      if entry.is_a?(String)
        # Serialized bytes (modern path)
        visited[filename] = entry

        decoded = Google::Protobuf::FileDescriptorProto.decode(entry)
        decoded.dependency.each do |dep|
          collect_dependencies(dep, visited)
        end
      else
        # FileDescriptor object (ObjectSpace fallback)
        visited[filename] = entry
      end
    end

    def index_services(fd, serialized)
      fd.each_service do |service|
        full_name = service.name
        @service_names << full_name
        @files_by_symbol[full_name] = serialized

        service.each_method do |method|
          @files_by_symbol["#{full_name}.#{method.name}"] = serialized
        end
      end
    rescue NoMethodError
      # File has no services
    end

    def index_messages(fd, serialized)
      fd.each_message do |msg|
        index_message_recursive(msg, serialized)
      end
    rescue NoMethodError
      # File has no messages
    end

    def index_message_recursive(msg, serialized)
      @files_by_symbol[msg.name] = serialized

      msg.each_nested_type do |nested|
        index_message_recursive(nested, serialized)
      end
    rescue NoMethodError
      # No nested types
    end

    def index_enums(fd, serialized)
      fd.each_enum do |enum|
        @files_by_symbol[enum.name] = serialized
      end
    rescue NoMethodError
      # File has no enums
    end
  end
end
