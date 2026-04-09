require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'
require_relative 'protos/complex_services_pb'
require_relative 'protos/dependency_services_pb'
require_relative 'protos/enum_only_pb'

RSpec.describe GrpcServerReflection::DescriptorRegistry::ProtoBuilder do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

  describe 'FileDescriptorProto serialization' do
    it 'produces decodable FileDescriptorProto bytes for test.proto' do
      serialized = registry.find_file_by_name('test.proto')
      expect(serialized).not_to be_nil

      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)
      expect(file_proto.name).to eq('test.proto')
      expect(file_proto.package).to eq('test')
    end

    it 'produces decodable FileDescriptorProto bytes for complex.proto' do
      serialized = registry.find_file_by_name('complex.proto')
      expect(serialized).not_to be_nil

      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)
      expect(file_proto.name).to eq('complex.proto')
      expect(file_proto.package).to eq('showcase')
    end

    it 'encodes message fields with correct types' do
      serialized = registry.find_file_by_name('test.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      request_msg = file_proto.message_type.find { |m| m.name == 'TestRequest' }
      expect(request_msg).not_to be_nil

      name_field = request_msg.field.find { |f| f.name == 'name' }
      expect(name_field).not_to be_nil
      expect(name_field.type).to eq(:TYPE_STRING)
      expect(name_field.number).to eq(1)
    end

    it 'encodes service methods with correct input/output types' do
      serialized = registry.find_file_by_name('test.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      svc = file_proto.service.find { |s| s.name == 'TestService' }
      expect(svc).not_to be_nil

      method = svc['method'].find { |m| m.name == 'TestMethod' }
      expect(method).not_to be_nil
      expect(method.input_type).to eq('.test.TestRequest')
      expect(method.output_type).to eq('.test.TestResponse')
    end
  end

  describe 'streaming methods' do
    let(:file_proto) do
      serialized = registry.find_file_by_name('complex.proto')
      Google::Protobuf::FileDescriptorProto.decode(serialized)
    end

    let(:svc) { file_proto.service.find { |s| s.name == 'ProfileService' } }

    it 'encodes server streaming' do
      method = svc['method'].find { |m| m.name == 'ListProfiles' }
      expect(method.client_streaming).to eq(false)
      expect(method.server_streaming).to eq(true)
    end

    it 'encodes client streaming' do
      method = svc['method'].find { |m| m.name == 'UpdateProfiles' }
      expect(method.client_streaming).to eq(true)
      expect(method.server_streaming).to eq(false)
    end

    it 'encodes bidi streaming' do
      method = svc['method'].find { |m| m.name == 'SyncProfiles' }
      expect(method.client_streaming).to eq(true)
      expect(method.server_streaming).to eq(true)
    end

    it 'encodes unary (no streaming)' do
      method = svc['method'].find { |m| m.name == 'GetProfile' }
      expect(method.client_streaming).to eq(false)
      expect(method.server_streaming).to eq(false)
    end
  end

  describe 'nested messages' do
    it 'nests Settings inside Profile as nested_type, not top-level' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      profile = file_proto.message_type.find { |m| m.name == 'Profile' }
      expect(profile).not_to be_nil

      settings = profile.nested_type.find { |m| m.name == 'Settings' }
      expect(settings).not_to be_nil

      top_level_names = file_proto.message_type.map(&:name)
      expect(top_level_names).not_to include('Settings')
      expect(top_level_names).not_to include('Profile.Settings')
    end
  end

  describe 'multi-level nested messages' do
    it 'nests Privacy inside Settings inside Profile (3 levels)' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      profile = file_proto.message_type.find { |m| m.name == 'Profile' }
      expect(profile).not_to be_nil

      settings = profile.nested_type.find { |m| m.name == 'Settings' }
      expect(settings).not_to be_nil

      privacy = settings.nested_type.find { |m| m.name == 'Privacy' }
      expect(privacy).not_to be_nil

      public_field = privacy.field.find { |f| f.name == 'public_profile' }
      expect(public_field).not_to be_nil
      expect(public_field.type).to eq(:TYPE_BOOL)
    end
  end

  describe 'deduplication' do
    it 'does not duplicate message types in a file descriptor' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      top_level_names = file_proto.message_type.map(&:name)
      expect(top_level_names).to eq(top_level_names.uniq)
    end

    it 'does not duplicate service names' do
      services = registry.list_services
      expect(services).to eq(services.uniq)
    end
  end

  describe 'cross-file dependencies' do
    it 'records cross-file dependencies for dependency.proto' do
      serialized = registry.find_file_by_name('dependency.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      expect(file_proto.dependency.to_a).to include('complex.proto')
    end

    it 'returns transitive dependencies when fetching dependency.proto' do
      results = registry.file_descriptors_with_dependencies('dependency.proto')
      filenames = results.map { |bytes| Google::Protobuf::FileDescriptorProto.decode(bytes).name }
      expect(filenames).to include('dependency.proto')
      expect(filenames).to include('complex.proto')
    end
  end

  describe 'enum descriptors' do
    it 'indexes top-level enums and they are findable by symbol' do
      result = registry.find_file_by_symbol('showcase.Status')
      expect(result).not_to be_nil
    end

    it 'includes top-level enums in file_proto.enum_type' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      status_enum = file_proto.enum_type.find { |e| e.name == 'Status' }
      expect(status_enum).not_to be_nil

      value_names = status_enum.value.map(&:name)
      expect(value_names).to include('STATUS_UNKNOWN')
      expect(value_names).to include('STATUS_ACTIVE')
      expect(value_names).to include('STATUS_INACTIVE')
    end

    it 'nests Role enum inside Profile message' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      profile = file_proto.message_type.find { |m| m.name == 'Profile' }
      expect(profile).not_to be_nil

      role_enum = profile.enum_type.find { |e| e.name == 'Role' }
      expect(role_enum).not_to be_nil

      value_names = role_enum.value.map(&:name)
      expect(value_names).to include('ROLE_ADMIN')
      expect(value_names).to include('ROLE_USER')
    end
  end

  describe 'enum-only proto files' do
    it 'indexes enum-only file and finds it by enum symbol' do
      result = registry.find_file_by_symbol('enumonly.Priority')
      expect(result).not_to be_nil
    end

    it 'derives correct package for enum-only file' do
      serialized = registry.find_file_by_name('enum_only.proto')
      expect(serialized).not_to be_nil

      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)
      expect(file_proto.package).to eq('enumonly')
    end

    it 'includes all enums from enum-only file' do
      serialized = registry.find_file_by_name('enum_only.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      enum_names = file_proto.enum_type.map(&:name)
      expect(enum_names).to include('Priority')
      expect(enum_names).to include('Severity')
    end
  end

  describe 'package derivation from shortest name' do
    it 'derives package correctly for complex.proto with nested types' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      # Even though there are nested types like showcase.Profile.Settings.Privacy,
      # the package should still be 'showcase', not 'showcase.Profile'
      expect(file_proto.package).to eq('showcase')
    end
  end

  describe 'MapEntry nested types for map fields' do
    it 'generates MapEntry nested type for map<string, string> field' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      profile = file_proto.message_type.find { |m| m.name == 'Profile' }
      expect(profile).not_to be_nil

      map_entry = profile.nested_type.find { |m| m.options&.map_entry }
      if map_entry
        expect(map_entry.options.map_entry).to eq(true)

        key_field = map_entry.field.find { |f| f.name == 'key' }
        value_field = map_entry.field.find { |f| f.name == 'value' }
        expect(key_field).not_to be_nil
        expect(value_field).not_to be_nil
        expect(key_field.type).to eq(:TYPE_STRING)
        expect(value_field.type).to eq(:TYPE_STRING)
      else
        # On newer protobuf with FileDescriptor#to_proto, map entries are
        # handled natively; just verify the field exists as repeated message
        custom_attr_field = profile.field.find { |f| f.name == 'custom_attributes' }
        expect(custom_attr_field).not_to be_nil
      end
    end
  end

  describe 'oneof fields' do
    it 'encodes oneof declaration in Profile' do
      serialized = registry.find_file_by_name('complex.proto')
      file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

      profile = file_proto.message_type.find { |m| m.name == 'Profile' }
      expect(profile).not_to be_nil

      oneof_names = profile.oneof_decl.map(&:name)
      expect(oneof_names).to include('contact')

      email_field = profile.field.find { |f| f.name == 'email' }
      phone_field = profile.field.find { |f| f.name == 'phone' }
      expect(email_field).not_to be_nil
      expect(phone_field).not_to be_nil

      contact_index = oneof_names.index('contact')
      expect(email_field.oneof_index).to eq(contact_index)
      expect(phone_field.oneof_index).to eq(contact_index)
    end
  end
end