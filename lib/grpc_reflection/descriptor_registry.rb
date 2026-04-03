module GrpcReflection
  class DescriptorRegistry
    attr_reader :service_names

    def initialize(services: nil)
      @files_by_name = {}
      @files_by_symbol = {}
      @service_names = []
      @extensions_by_type = {}
      @allowed_services = if services
                            services.map { |s| s.service_name }.compact
                          end

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
      file_messages = {}  # filename => { file_descriptor:, descriptors: [] }
      file_enums = {}     # filename => [Google::Protobuf::EnumDescriptor, ...]
      file_services = {}  # filename => [{ service_name:, klass: }, ...]

      # Collect message descriptors and service classes
      ObjectSpace.each_object(Class).each do |klass|
        if safe_respond_to?(klass, :descriptor)
          desc = safe_call(klass, :descriptor)
          if desc.is_a?(Google::Protobuf::Descriptor)
            fd = desc.file_descriptor
            if fd
              filename = fd.name
              file_messages[filename] ||= { file_descriptor: fd, descriptors: [] }
              file_messages[filename][:descriptors] << desc
            end
          end
        end

        if safe_respond_to?(klass, :service_name)
          begin
            next unless klass.included_modules.include?(GRPC::GenericService)
          rescue StandardError
            next
          end

          service_name = klass.service_name
          next if service_name.nil? || service_name.empty?
          next if @service_names.include?(service_name)
          next if @allowed_services && !@allowed_services.include?(service_name)

          @service_names << service_name

          filename = find_service_filename(klass)
          if filename
            file_services[filename] ||= []
            file_services[filename] << { service_name: service_name, klass: klass }
          end
        end
      end

      # Collect enum descriptors
      ObjectSpace.each_object(Google::Protobuf::EnumDescriptor).each do |enum_desc|
        fd = enum_desc.file_descriptor
        next unless fd

        filename = fd.name
        file_enums[filename] ||= []
        file_enums[filename] << enum_desc

        # Ensure we have the file_descriptor recorded
        file_messages[filename] ||= { file_descriptor: fd, descriptors: [] }
      end

      # Build symbol-to-filename index
      symbol_to_filename = {}
      file_messages.each do |filename, data|
        data[:descriptors].each { |desc| symbol_to_filename[desc.name] = filename }
      end
      file_enums.each do |filename, enums|
        enums.each { |desc| symbol_to_filename[desc.name] = filename }
      end
      file_services.each do |filename, entries|
        entries.each { |entry| symbol_to_filename[entry[:service_name]] = filename }
      end

      # Pass 2: Build serialized FileDescriptorProtos with dependencies
      all_filenames = (file_messages.keys + file_services.keys + file_enums.keys).uniq
      all_filenames.each do |filename|
        msgs = file_messages[filename]
        fd_obj = msgs ? msgs[:file_descriptor] : nil
        msg_descriptors = msgs ? msgs[:descriptors] : []
        enum_descriptors = file_enums[filename] || []
        svc_entries = file_services[filename] || []

        serialized = build_file_descriptor_proto(filename, fd_obj, msg_descriptors, enum_descriptors, svc_entries, symbol_to_filename)
        @files_by_name[filename] = serialized

        msg_descriptors.each { |desc| @files_by_symbol[desc.name] = serialized }
        enum_descriptors.each { |desc| @files_by_symbol[desc.name] = serialized }
        svc_entries.each { |entry| @files_by_symbol[entry[:service_name]] = serialized }
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

    def build_file_descriptor_proto(filename, fd_obj, msg_descriptors, enum_descriptors, svc_entries, symbol_to_filename)
      package = extract_package(msg_descriptors, enum_descriptors, svc_entries)
      dependencies = []

      # Collect all symbol names defined in this file
      local_symbols = {}
      msg_descriptors.each { |desc| local_symbols[desc.name] = true }
      enum_descriptors.each { |desc| local_symbols[desc.name] = true }

      file_proto = Google::Protobuf::FileDescriptorProto.new(
        name: filename,
        package: package,
        syntax: fd_obj ? fd_obj.syntax.to_s : 'proto3'
      )

      # Deduplicate and separate top-level from nested
      seen_names = {}
      top_level = []
      nested = []

      msg_descriptors.each do |desc|
        short_name = remove_package(desc.name, package)
        next if seen_names[short_name]
        seen_names[short_name] = true

        if short_name.include?('.')
          nested << desc
        else
          top_level << desc
        end
      end

      # Build top-level messages
      top_level_protos = {}
      top_level.each do |desc|
        short_name = remove_package(desc.name, package)
        msg_proto = build_message_descriptor_proto(desc, package)
        top_level_protos[short_name] = msg_proto
        file_proto.message_type << msg_proto
      end

      # Nest child messages inside their parents (supports multi-level nesting)
      # Sort by depth so parents are processed before children
      nested.sort_by { |desc| remove_package(desc.name, package).count('.') }.each do |desc|
        short_name = remove_package(desc.name, package)
        parts = short_name.split('.')
        child_name = parts.last
        parent_name = parts[0..-2].join('.')

        child_proto = build_message_descriptor_proto(desc, package)
        child_proto.name = child_name

        parent = top_level_protos[parent_name]
        if parent
          parent.nested_type << child_proto
          # Register so deeper levels can find this as their parent
          top_level_protos[short_name] = child_proto
        else
          file_proto.message_type << child_proto
        end
      end

      # Add enums (top-level and nested)
      seen_enums = {}
      enum_descriptors.each do |enum_desc|
        short_name = remove_package(enum_desc.name, package)
        next if seen_enums[short_name]
        seen_enums[short_name] = true

        enum_proto = build_enum_descriptor_proto(enum_desc, package)

        if short_name.include?('.')
          # Nested enum — place inside parent message
          parts = short_name.split('.')
          parent_name = parts[0..-2].join('.')
          enum_proto.name = parts.last
          if top_level_protos[parent_name]
            top_level_protos[parent_name].enum_type << enum_proto
          else
            file_proto.enum_type << enum_proto
          end
        else
          file_proto.enum_type << enum_proto
        end
      end

      # Add services
      svc_entries.each do |entry|
        file_proto.service << build_service_descriptor_proto(entry, package)
      end

      # Collect cross-file dependencies from field type references
      collect_file_dependencies(file_proto, local_symbols, dependencies, symbol_to_filename)
      dependencies.uniq.each { |dep| file_proto.dependency << dep }

      Google::Protobuf::FileDescriptorProto.encode(file_proto)
    end

    def build_enum_descriptor_proto(enum_desc, package)
      short_name = remove_package(enum_desc.name, package)

      enum_proto = Google::Protobuf::EnumDescriptorProto.new(name: short_name)

      enum_desc.each do |name, number|
        enum_proto.value << Google::Protobuf::EnumValueDescriptorProto.new(
          name: name.to_s,
          number: number
        )
      end

      enum_proto
    end

    def collect_file_dependencies(file_proto, local_symbols, dependencies, symbol_to_filename)
      file_proto.message_type.each do |msg|
        collect_msg_dependencies(msg, local_symbols, dependencies, symbol_to_filename)
      end

      file_proto.service.each do |svc|
        svc['method'].each do |m|
          check_type_dependency(m.input_type, local_symbols, dependencies, symbol_to_filename)
          check_type_dependency(m.output_type, local_symbols, dependencies, symbol_to_filename)
        end
      end
    end

    def collect_msg_dependencies(msg_proto, local_symbols, dependencies, symbol_to_filename)
      msg_proto.field.each do |field|
        next if field.type_name.nil? || field.type_name.empty?
        check_type_dependency(field.type_name, local_symbols, dependencies, symbol_to_filename)
      end

      msg_proto.nested_type.each do |nested|
        collect_msg_dependencies(nested, local_symbols, dependencies, symbol_to_filename)
      end
    end

    def check_type_dependency(type_name, local_symbols, dependencies, symbol_to_filename)
      return if type_name.nil? || type_name.empty?

      full_name = type_name.start_with?('.') ? type_name[1..] : type_name

      unless local_symbols[full_name]
        dep_filename = symbol_to_filename[full_name]
        dependencies << dep_filename if dep_filename
      end
    end

    def build_message_descriptor_proto(desc, package)
      short_name = remove_package(desc.name, package)

      msg_proto = Google::Protobuf::DescriptorProto.new(name: short_name)
      pool = Google::Protobuf::DescriptorPool.generated_pool

      desc.each do |field|
        field_proto = Google::Protobuf::FieldDescriptorProto.new(
          name: field.name,
          number: field.number,
          type: proto_field_type(field.type),
          label: proto_field_label(field.label),
          json_name: field.json_name
        )

        if field.type == :message || field.type == :enum
          if field.submsg_name && field.submsg_name.include?('_MapEntry_')
            # Map field — generate nested MapEntry type
            map_entry = build_map_entry(field, pool)
            if map_entry
              msg_proto.nested_type << map_entry
              field_proto.type_name = ".#{desc.name}.#{map_entry.name}"
            else
              field_proto.type_name = ".#{field.submsg_name}"
            end
          elsif field.submsg_name
            field_proto.type_name = ".#{field.submsg_name}"
          end
        end

        msg_proto.field << field_proto
      end

      # Add oneofs
      oneof_index = 0
      desc.each_oneof do |oneof|
        msg_proto.oneof_decl << Google::Protobuf::OneofDescriptorProto.new(name: oneof.name)

        desc.each do |field|
          if belongs_to_oneof?(field, oneof)
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

    def build_map_entry(field, pool)
      entry_desc = pool.lookup(field.submsg_name)
      return nil unless entry_desc

      # Extract a clean entry name from the submsg_name
      # e.g. "...Response_MapEntry_custom_attributes" => "CustomAttributesEntry"
      raw_suffix = field.submsg_name.split('_MapEntry_').last
      entry_name = raw_suffix.split('_').map(&:capitalize).join + 'Entry'

      entry_proto = Google::Protobuf::DescriptorProto.new(
        name: entry_name,
        options: Google::Protobuf::MessageOptions.new(map_entry: true)
      )

      entry_desc.each do |entry_field|
        fp = Google::Protobuf::FieldDescriptorProto.new(
          name: entry_field.name,
          number: entry_field.number,
          type: proto_field_type(entry_field.type),
          label: proto_field_label(entry_field.label)
        )
        if (entry_field.type == :message || entry_field.type == :enum) && entry_field.submsg_name
          fp.type_name = ".#{entry_field.submsg_name}"
        end
        entry_proto.field << fp
      end

      entry_proto
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

    def extract_package(msg_descriptors, enum_descriptors, svc_entries)
      # Collect all fully-qualified names
      all_names = []
      svc_entries.each { |e| all_names << e[:service_name] }
      msg_descriptors.each { |d| all_names << d.name }
      enum_descriptors.each { |d| all_names << d.name }

      return '' if all_names.empty?

      # The package is the longest common prefix of all names (split by dot),
      # excluding the final component(s) that are type names.
      # Use the shortest name — its parent is the most reliable package.
      shortest = all_names.min_by { |n| n.split('.').length }
      parts = shortest.split('.')
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

    def belongs_to_oneof?(field, oneof)
      oneof.each do |oneof_field|
        return true if oneof_field.name == field.name
      end
      false
    rescue
      false
    end

    FIELD_TYPE_MAP = {
      double: :TYPE_DOUBLE, float: :TYPE_FLOAT,
      int64: :TYPE_INT64, uint64: :TYPE_UINT64, int32: :TYPE_INT32,
      fixed64: :TYPE_FIXED64, fixed32: :TYPE_FIXED32,
      bool: :TYPE_BOOL, string: :TYPE_STRING, bytes: :TYPE_BYTES,
      uint32: :TYPE_UINT32, enum: :TYPE_ENUM,
      sfixed32: :TYPE_SFIXED32, sfixed64: :TYPE_SFIXED64,
      sint32: :TYPE_SINT32, sint64: :TYPE_SINT64,
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
        next if @allowed_services && !@allowed_services.include?(full_name)
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
