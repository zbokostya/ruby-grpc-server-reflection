module GrpcReflection
  class Service < Grpc::Reflection::V1::ServerReflection::Service
    def server_reflection_info(requests, _call)
      registry = DescriptorRegistry.new

      Enumerator.new do |yielder|
        requests.each do |request|
          response = handle_request(request, registry)
          yielder << response
        end
      end
    end

    private

    def handle_request(request, registry)
      response = Grpc::Reflection::V1::ServerReflectionResponse.new(
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
        Grpc::Reflection::V1::ServiceResponse.new(name: name)
      end
      response.list_services_response = Grpc::Reflection::V1::ListServiceResponse.new(
        service: services
      )
    end

    def handle_file_by_filename(response, filename, registry)
      descriptors = registry.file_descriptors_with_dependencies(filename)
      if descriptors.empty?
        handle_error(response, GRPC::Core::StatusCodes::NOT_FOUND, "File not found: #{filename}")
      else
        response.file_descriptor_response = Grpc::Reflection::V1::FileDescriptorResponse.new(
          file_descriptor_proto: serialize_descriptors(descriptors)
        )
      end
    end

    def handle_file_containing_symbol(response, symbol, registry)
      file_entry = registry.find_file_by_symbol(symbol)
      if file_entry.nil?
        handle_error(response, GRPC::Core::StatusCodes::NOT_FOUND, "Symbol not found: #{symbol}")
      else
        if file_entry.is_a?(String)
          decoded = Google::Protobuf::FileDescriptorProto.decode(file_entry)
          filename = decoded.name
        else
          filename = file_entry.name
        end
        descriptors = registry.file_descriptors_with_dependencies(filename)
        response.file_descriptor_response = Grpc::Reflection::V1::FileDescriptorResponse.new(
          file_descriptor_proto: serialize_descriptors(descriptors)
        )
      end
    end

    def handle_file_containing_extension(response, ext_request, registry)
      handle_error(response, GRPC::Core::StatusCodes::NOT_FOUND,
        "Extension not found for type: #{ext_request.containing_type}, number: #{ext_request.extension_number}")
    end

    def handle_all_extension_numbers(response, type_name, registry)
      numbers = registry.find_extension_numbers(type_name)
      response.all_extension_numbers_response = Grpc::Reflection::V1::ExtensionNumberResponse.new(
        base_type_name: type_name,
        extension_number: numbers
      )
    end

    def handle_error(response, code, message)
      response.error_response = Grpc::Reflection::V1::ErrorResponse.new(
        error_code: code,
        error_message: message
      )
    end

    def serialize_descriptors(descriptors)
      descriptors.map do |desc|
        if desc.is_a?(String)
          desc
        elsif desc.respond_to?(:to_proto)
          desc.to_proto
        else
          Google::Protobuf::FileDescriptorProto.encode(
            Google::Protobuf::FileDescriptorProto.new(name: desc.name)
          )
        end
      end
    end
  end
end
