module GrpcServerReflection
  class DescriptorRegistry
    class DependencyResolver
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

      private

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
    end
  end
end
