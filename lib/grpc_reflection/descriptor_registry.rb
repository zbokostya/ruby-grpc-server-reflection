module GrpcReflection
  class DescriptorRegistry
    attr_reader :service_names

    def initialize
      @files_by_name = {}
      @files_by_symbol = {}
      @service_names = []

      build_index
    end

    def list_services
      @service_names
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
        next unless klass.included_modules.include?(GRPC::GenericService)
        next unless klass.respond_to?(:service_name)

        service_name = klass.service_name
        next if service_name.nil? || service_name.empty?

        @service_names << service_name
      end
    end

    def index_file_descriptors
      ObjectSpace.each_object(Google::Protobuf::FileDescriptor).each do |fd|
        @files_by_name[fd.name] = fd
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
