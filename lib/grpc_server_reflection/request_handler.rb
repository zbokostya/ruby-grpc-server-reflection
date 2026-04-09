module GrpcServerReflection
  module RequestHandler
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def registry_for(allowed)
        @mutex ||= Mutex.new
        @mutex.synchronize do
          cache_key = allowed ? allowed.sort : nil
          if @registry_cache_key != cache_key
            @registry = nil
            @registry_cache_key = cache_key
          end
          @registry ||= DescriptorRegistry.new(allowed_service_names: allowed)
        end
      end

      def reset_registry!
        @mutex ||= Mutex.new
        @mutex.synchronize do
          @registry = nil
          @registry_cache_key = nil
        end
      end
    end

    def server_reflection_info(requests, call)
      registry = self.class.registry_for(allowed_service_names(call))

      Enumerator.new do |yielder|
        requests.each do |request|
          response = handle_request(request, registry)
          yielder << response
        end
      end
    end

    private

    def proto_module
      raise NotImplementedError
    end

    def allowed_service_names(call)
      if GrpcServerReflection.services
        return GrpcServerReflection.services.map(&:service_name).compact
      end

      server = find_server(call)
      return nil unless server

      rpc_descs = server.instance_variable_get(:@rpc_descs)
      return nil unless rpc_descs

      rpc_descs.keys.map do |key|
        parts = key.to_s.split('/')
        parts[1] if parts.length >= 3
      end.compact.uniq
    end

    def find_server(call)
      return nil unless call
      ObjectSpace.each_object(GRPC::RpcServer).first
    rescue
      nil
    end

    def handle_request(request, registry)
      response = proto_module::ServerReflectionResponse.new(
        valid_host: request.host,
        original_request: request
      )

      case request.message_request
      when :list_services
        handle_list_services(response, registry)
      when :file_by_filename
        handle_file_by_filename(response, request.file_by_filename, registry)
      when :file_containing_symbol
        handle_file_containing_symbol(response, request.file_containing_symbol, registry)
      when :file_containing_extension
        handle_file_containing_extension(response, request.file_containing_extension, registry)
      when :all_extension_numbers_of_type
        handle_all_extension_numbers(response, request.all_extension_numbers_of_type, registry)
      else
        handle_error(response, GRPC::Core::StatusCodes::UNIMPLEMENTED, 'Request not implemented')
      end

      response
    end

    def handle_list_services(response, registry)
      services = registry.list_services.map do |name|
        proto_module::ServiceResponse.new(name: name)
      end
      response.list_services_response = proto_module::ListServiceResponse.new(
        service: services
      )
    end

    def handle_file_by_filename(response, filename, registry)
      descriptors = registry.file_descriptors_with_dependencies(filename)
      if descriptors.empty?
        handle_error(response, GRPC::Core::StatusCodes::NOT_FOUND, "File not found: #{filename}")
      else
        response.file_descriptor_response = proto_module::FileDescriptorResponse.new(
          file_descriptor_proto: descriptors
        )
      end
    end

    def handle_file_containing_symbol(response, symbol, registry)
      filename = registry.find_filename_by_symbol(symbol)
      if filename.nil?
        handle_error(response, GRPC::Core::StatusCodes::NOT_FOUND, "Symbol not found: #{symbol}")
      else
        descriptors = registry.file_descriptors_with_dependencies(filename)
        response.file_descriptor_response = proto_module::FileDescriptorResponse.new(
          file_descriptor_proto: descriptors
        )
      end
    end

    def handle_file_containing_extension(response, ext_request, registry)
      handle_error(response, GRPC::Core::StatusCodes::NOT_FOUND,
        "Extension not found for type: #{ext_request.containing_type}, number: #{ext_request.extension_number}")
    end

    def handle_all_extension_numbers(response, type_name, registry)
      numbers = registry.find_extension_numbers(type_name)
      response.all_extension_numbers_response = proto_module::ExtensionNumberResponse.new(
        base_type_name: type_name,
        extension_number: numbers
      )
    end

    def handle_error(response, code, message)
      response.error_response = proto_module::ErrorResponse.new(
        error_code: code,
        error_message: message
      )
    end
  end
end
