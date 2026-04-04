module GrpcServerReflection
  class DescriptorRegistry
    class FileDescriptorIndexer
      def initialize(allowed_services:)
        @allowed_services = allowed_services
      end

      def build_index(pool, files_by_symbol:, serialized_files:, dependencies:, service_names:)
        pool.each_file_descriptor do |fd|
          serialized = fd.to_proto
          filename = fd.name

          serialized_files[filename] = serialized

          decoded = Google::Protobuf::FileDescriptorProto.decode(serialized)
          dependencies[filename] = decoded.dependency.to_a

          index_services(fd, filename, files_by_symbol: files_by_symbol, service_names: service_names)
          index_messages(fd, filename, files_by_symbol: files_by_symbol)
          index_enums(fd, filename, files_by_symbol: files_by_symbol)
        end
      end

      private

      def index_services(fd, filename, files_by_symbol:, service_names:)
        fd.each_service do |service|
          full_name = service.name
          next if @allowed_services && !@allowed_services.include?(full_name)
          service_names << full_name
          files_by_symbol[full_name] = filename

          service.each_method do |method|
            files_by_symbol["#{full_name}.#{method.name}"] = filename
          end
        end
      rescue NoMethodError => e
        raise unless e.name == :each_service
      end

      def index_messages(fd, filename, files_by_symbol:)
        fd.each_message do |msg|
          index_message_recursive(msg, filename, files_by_symbol: files_by_symbol)
        end
      rescue NoMethodError => e
        raise unless e.name == :each_message
      end

      def index_message_recursive(msg, filename, files_by_symbol:)
        files_by_symbol[msg.name] = filename

        msg.each_nested_type do |nested|
          index_message_recursive(nested, filename, files_by_symbol: files_by_symbol)
        end
      rescue NoMethodError => e
        raise unless e.name == :each_nested_type
      end

      def index_enums(fd, filename, files_by_symbol:)
        fd.each_enum do |enum|
          files_by_symbol[enum.name] = filename
        end
      rescue NoMethodError => e
        raise unless e.name == :each_enum
      end
    end
  end
end
