module GrpcServerReflection
  class DescriptorRegistry
    class ObjectSpaceIndexer
      include TypeMapping

      def initialize(allowed_services:)
        @allowed_services = allowed_services
        @proto_builder = ProtoBuilder.new
      end

      def build_index(files_by_symbol:, serialized_files:, dependencies:, service_names:)
        file_messages = {}  # filename => { file_descriptor:, descriptors: [] }
        file_enums = {}     # filename => [Google::Protobuf::EnumDescriptor, ...]
        file_services = {}  # filename => [{ service_name:, klass: }, ...]

        scan_object_space(file_messages, file_enums, file_services, service_names)

        symbol_to_filename = build_symbol_index(file_messages, file_enums, file_services)

        build_serialized_files(
          file_messages, file_enums, file_services, symbol_to_filename,
          files_by_symbol: files_by_symbol, serialized_files: serialized_files, dependencies: dependencies
        )
      end

      private

      def scan_object_space(file_messages, file_enums, file_services, service_names)
        ObjectSpace.each_object(Class).each do |klass|
          scan_message_class(klass, file_messages)
          scan_service_class(klass, file_services, service_names)
        end

        ObjectSpace.each_object(Google::Protobuf::EnumDescriptor).each do |enum_desc|
          fd = enum_desc.file_descriptor
          next unless fd

          filename = fd.name
          file_enums[filename] ||= []
          file_enums[filename] << enum_desc

          file_messages[filename] ||= { file_descriptor: fd, descriptors: [] }
        end
      end

      def scan_message_class(klass, file_messages)
        return unless safe_respond_to?(klass, :descriptor)

        desc = safe_call(klass, :descriptor)
        return unless desc.is_a?(Google::Protobuf::Descriptor)

        fd = desc.file_descriptor
        return unless fd

        filename = fd.name
        file_messages[filename] ||= { file_descriptor: fd, descriptors: [] }
        file_messages[filename][:descriptors] << desc
      end

      def scan_service_class(klass, file_services, service_names)
        return unless safe_respond_to?(klass, :service_name)

        begin
          return unless klass.included_modules.include?(GRPC::GenericService)
        rescue StandardError
          return
        end

        service_name = klass.service_name
        return if service_name.nil? || service_name.empty?
        return if service_names.include?(service_name)
        return if @allowed_services && !@allowed_services.include?(service_name)

        service_names << service_name

        filename = find_service_filename(klass)
        if filename
          file_services[filename] ||= []
          file_services[filename] << { service_name: service_name, klass: klass }
        end
      end

      def find_service_filename(klass)
        return nil unless klass.respond_to?(:rpc_descs)

        klass.rpc_descs.each_value do |rpc_desc|
          input_type = rpc_desc.input
          input_type = input_type.type if input_type.is_a?(GRPC::RpcDesc::Stream)
          if safe_respond_to?(input_type, :descriptor)
            input_desc = safe_call(input_type, :descriptor)
            if input_desc && input_desc.respond_to?(:file_descriptor) && input_desc.file_descriptor
              return input_desc.file_descriptor.name
            end
          end
        end
        nil
      end

      def build_symbol_index(file_messages, file_enums, file_services)
        symbol_to_filename = {}

        file_messages.each do |filename, data|
          data[:descriptors].each { |desc| symbol_to_filename[desc.name] = filename }
        end
        file_enums.each do |filename, enums|
          enums.each { |desc| symbol_to_filename[desc.name] = filename }
        end
        file_services.each do |filename, entries|
          entries.each do |entry|
            symbol_to_filename[entry[:service_name]] = filename
            if entry[:klass].respond_to?(:rpc_descs)
              entry[:klass].rpc_descs.each_key do |method_name|
                symbol_to_filename["#{entry[:service_name]}.#{method_name}"] = filename
              end
            end
          end
        end

        symbol_to_filename
      end

      def build_serialized_files(file_messages, file_enums, file_services, symbol_to_filename, files_by_symbol:, serialized_files:, dependencies:)
        all_filenames = (file_messages.keys + file_services.keys + file_enums.keys).uniq

        all_filenames.each do |filename|
          msgs = file_messages[filename]
          fd_obj = msgs ? msgs[:file_descriptor] : nil
          msg_descriptors = msgs ? msgs[:descriptors] : []
          enum_descriptors = file_enums[filename] || []
          svc_entries = file_services[filename] || []

          file_deps = []
          serialized = @proto_builder.build_file_descriptor_proto(
            filename, fd_obj, msg_descriptors, enum_descriptors, svc_entries, symbol_to_filename, file_deps
          )
          serialized_files[filename] = serialized
          dependencies[filename] = file_deps

          msg_descriptors.each { |desc| files_by_symbol[desc.name] = filename }
          enum_descriptors.each { |desc| files_by_symbol[desc.name] = filename }
          svc_entries.each do |entry|
            files_by_symbol[entry[:service_name]] = filename
            if entry[:klass].respond_to?(:rpc_descs)
              entry[:klass].rpc_descs.each_key do |method_name|
                files_by_symbol["#{entry[:service_name]}.#{method_name}"] = filename
              end
            end
          end
        end
      end
    end
  end
end
