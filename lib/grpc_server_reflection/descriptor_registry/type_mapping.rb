module GrpcServerReflection
  class DescriptorRegistry
    module TypeMapping
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

      LABEL_MAP = {
        optional: :LABEL_OPTIONAL,
        required: :LABEL_REQUIRED,
        repeated: :LABEL_REPEATED,
      }.freeze

      def proto_field_type(type)
        mapped = FIELD_TYPE_MAP[type]
        unless mapped
          warn "[grpc-server-reflection] Unknown protobuf field type: #{type.inspect}, defaulting to TYPE_STRING"
          return :TYPE_STRING
        end
        mapped
      end

      def proto_field_label(label)
        LABEL_MAP[label] || :LABEL_OPTIONAL
      end

      def descriptor_full_name(type)
        if safe_respond_to?(type, :descriptor) && (desc = safe_call(type, :descriptor))
          desc.name
        else
          type.name.gsub('::', '.')
        end
      end

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

      def remove_package(full_name, package)
        if package && !package.empty? && full_name.start_with?("#{package}.")
          full_name.sub("#{package}.", '')
        else
          full_name
        end
      end
    end
  end
end
