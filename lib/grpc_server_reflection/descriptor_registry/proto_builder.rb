module GrpcServerReflection
  class DescriptorRegistry
    class ProtoBuilder
      include TypeMapping

      def initialize
        @dependency_resolver = DependencyResolver.new
      end

      def build_file_descriptor_proto(filename, fd_obj, msg_descriptors, enum_descriptors, svc_entries, symbol_to_filename, out_deps)
        package = extract_package(msg_descriptors, enum_descriptors, svc_entries)
        dependencies = []

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

        # Nest child messages inside their parents
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

        # Collect cross-file dependencies
        @dependency_resolver.collect_file_dependencies(file_proto, local_symbols, dependencies, symbol_to_filename)
        dependencies.uniq!
        dependencies.each { |dep| file_proto.dependency << dep }
        out_deps.concat(dependencies)

        Google::Protobuf::FileDescriptorProto.encode(file_proto)
      end

      private

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

      def build_map_entry(field, pool)
        entry_desc = pool.lookup(field.submsg_name)
        return nil unless entry_desc

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

      def extract_package(msg_descriptors, enum_descriptors, svc_entries)
        all_names = []
        svc_entries.each { |e| all_names << e[:service_name] }
        msg_descriptors.each { |d| all_names << d.name }
        enum_descriptors.each { |d| all_names << d.name }

        return '' if all_names.empty?

        shortest = all_names.min_by { |n| n.split('.').length }
        parts = shortest.split('.')
        parts.length > 1 ? parts[0..-2].join('.') : ''
      end

      def belongs_to_oneof?(field, oneof)
        oneof.each do |oneof_field|
          return true if oneof_field.name == field.name
        end
        false
      rescue
        false
      end
    end
  end
end
