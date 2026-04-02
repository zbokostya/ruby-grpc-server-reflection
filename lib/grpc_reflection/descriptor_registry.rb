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

    # --- ObjectSpace fallback for older protobuf versions ---

    def build_index_from_object_space
      # Collect raw data grouped by file
      file_messages = {}  # filename => [Google::Protobuf::Descriptor, ...]
      file_services = {}  # filename => [{ name:, rpc_descs: }, ...]

      # Collect message descriptors
      ObjectSpace.each_object(Class).each do |klass|
        next unless safe_respond_to?(klass, :descriptor)

        desc = safe_call(klass, :descriptor)
        next unless desc.is_a?(Google::Protobuf::Descriptor)

        fd = desc.file_descriptor
        next unless fd

        filename = fd.name
        file_messages[filename] ||= { file_descriptor: fd, descriptors: [] }
        file_messages[filename][:descriptors] << desc
      end

      # Collect service descriptors
      ObjectSpace.each_object(Class).each do |klass|
        next unless safe_respond_to?(klass, :service_name)
        next unless klass.included_modules.include?(GRPC::GenericService)

        service_name = klass.service_name
        next if service_name.nil? || service_name.empty?

        @service_names << service_name

        # Find the file this service belongs to via its RPC input types
        filename = nil
        if klass.respond_to?(:rpc_descs)
          klass.rpc_descs.each_value do |rpc_desc|
            input_type = rpc_desc.input
            input_type = input_type.type if input_type.is_a?(GRPC::RpcDesc::Stream)
            if safe_respond_to?(input_type, :descriptor)
              input_desc = safe_call(input_type, :descriptor)
              if input_desc && input_desc.respond_to?(:file_descriptor) && input_desc.file_descriptor
                filename = input_desc.file_descriptor.name
                break
              end
            end
          end
        end

        if filename
          file_services[filename] ||= []
          file_services[filename] << { service_name: service_name, klass: klass }
        end
      end

      # Build serialized FileDescriptorProtos for each file
      all_filenames = (file_messages.keys + file_services.keys).uniq
      all_filenames.each do |filename|
        msgs = file_messages[filename]
        fd_obj = msgs ? msgs[:file_descriptor] : nil
        msg_descriptors = msgs ? msgs[:descriptors] : []
        svc_entries = file_services[filename] || []

        serialized = build_file_descriptor_proto(filename, fd_obj, msg_descriptors, svc_entries)
        @files_by_name[filename] = serialized

        # Index symbols
        msg_descriptors.each { |desc| @files_by_symbol[desc.name] = serialized }
        svc_entries.each { |entry| @files_by_symbol[entry[:service_name]] = serialized }
      end
    end

    def build_file_descriptor_proto(filename, fd_obj, msg_descriptors, svc_entries)
      # Determine package from message/service names
      package = extract_package(msg_descriptors, svc_entries)

      file_proto = Google::Protobuf::FileDescriptorProto.new(
        name: filename,
        package: package,
        syntax: fd_obj ? fd_obj.syntax.to_s : 'proto3'
      )

      # Add messages
      msg_descriptors.each do |desc|
        file_proto.message_type << build_message_descriptor_proto(desc, package)
      end

      # Add services
      svc_entries.each do |entry|
        file_proto.service << build_service_descriptor_proto(entry, package)
      end

      Google::Protobuf::FileDescriptorProto.encode(file_proto)
    end

    def build_message_descriptor_proto(desc, package)
      short_name = remove_package(desc.name, package)

      msg_proto = Google::Protobuf::DescriptorProto.new(name: short_name)

      desc.each do |field|
        field_proto = Google::Protobuf::FieldDescriptorProto.new(
          name: field.name,
          number: field.number,
          type: proto_field_type(field.type),
          label: proto_field_label(field.label),
          json_name: field.json_name
        )

        if field.type == :message || field.type == :enum
          field_proto.type_name = ".#{field.submsg_name}" if field.submsg_name
        end

        msg_proto.field << field_proto
      end

      # Add oneofs
      oneof_index = 0
      desc.each_oneof do |oneof|
        msg_proto.oneof_decl << Google::Protobuf::OneofDescriptorProto.new(name: oneof.name)

        # Mark fields belonging to this oneof
        desc.each do |field|
          if field.respond_to?(:has?) && belongs_to_oneof?(field, oneof, desc)
            # Find the field in msg_proto.field and set oneof_index
            msg_proto.field.each do |fp|
              if fp.name == field.name
                fp.oneof_index = oneof_index
                break
              end
            end
          end
        end
        oneof_index += 1
      end

      msg_proto
    end

    def build_service_descriptor_proto(entry, package)
      short_name = remove_package(entry[:service_name], package)
      klass = entry[:klass]

      svc_proto = Google::Protobuf::ServiceDescriptorProto.new(name: short_name)

      if klass.respond_to?(:rpc_descs)
        klass.rpc_descs.each do |method_name, rpc_desc|
          input_type = rpc_desc.input
          output_type = rpc_desc.output
          client_streaming = input_type.is_a?(GRPC::RpcDesc::Stream)
          server_streaming = output_type.is_a?(GRPC::RpcDesc::Stream)
          input_type = input_type.type if client_streaming
          output_type = output_type.type if server_streaming

          input_name = descriptor_full_name(input_type)
          output_name = descriptor_full_name(output_type)

          method_proto = Google::Protobuf::MethodDescriptorProto.new(
            name: method_name.to_s,
            input_type: ".#{input_name}",
            output_type: ".#{output_name}",
            client_streaming: client_streaming,
            server_streaming: server_streaming
          )
          svc_proto['method'] << method_proto
        end
      end

      svc_proto
    end

    def extract_package(msg_descriptors, svc_entries)
      # Get package from the first available fully-qualified name
      name = if svc_entries.any?
               svc_entries.first[:service_name]
             elsif msg_descriptors.any?
               msg_descriptors.first.name
             end
      return '' unless name

      parts = name.split('.')
      parts.length > 1 ? parts[0..-2].join('.') : ''
    end

    def remove_package(full_name, package)
      if package && !package.empty? && full_name.start_with?("#{package}.")
        full_name.sub("#{package}.", '')
      else
        full_name
      end
    end

    def descriptor_full_name(type)
      if safe_respond_to?(type, :descriptor) && (desc = safe_call(type, :descriptor))
        desc.name
      else
        type.name.gsub('::', '.')
      end
    end

    FIELD_TYPE_MAP = {
      double: :TYPE_DOUBLE,
      float: :TYPE_FLOAT,
      int64: :TYPE_INT64,
      uint64: :TYPE_UINT64,
      int32: :TYPE_INT32,
      fixed64: :TYPE_FIXED64,
      fixed32: :TYPE_FIXED32,
      bool: :TYPE_BOOL,
      string: :TYPE_STRING,
      bytes: :TYPE_BYTES,
      uint32: :TYPE_UINT32,
      enum: :TYPE_ENUM,
      sfixed32: :TYPE_SFIXED32,
      sfixed64: :TYPE_SFIXED64,
      sint32: :TYPE_SINT32,
      sint64: :TYPE_SINT64,
      message: :TYPE_MESSAGE,
    }.freeze

    def proto_field_type(type)
      FIELD_TYPE_MAP[type] || :TYPE_STRING
    end

    LABEL_MAP = {
      optional: :LABEL_OPTIONAL,
      required: :LABEL_REQUIRED,
      repeated: :LABEL_REPEATED,
    }.freeze

    def proto_field_label(label)
      LABEL_MAP[label] || :LABEL_OPTIONAL
    end

    def belongs_to_oneof?(field, oneof, desc)
      oneof.each do |oneof_field|
        return true if oneof_field.name == field.name
      end
      false
    rescue
      false
    end

    # --- Common methods ---

    def safe_respond_to?(obj, method)
      obj.respond_to?(method)
    rescue StandardError, NotImplementedError
      false
    end

    def safe_call(obj, method)
      obj.send(method)
    rescue StandardError, NotImplementedError
      nil
    end

    def collect_dependencies(filename, visited)
      return if visited.key?(filename)

      entry = @files_by_name[filename]
      return unless entry

      visited[filename] = entry

      if entry.is_a?(String)
        decoded = Google::Protobuf::FileDescriptorProto.decode(entry)
        decoded.dependency.each do |dep|
          collect_dependencies(dep, visited)
        end
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
