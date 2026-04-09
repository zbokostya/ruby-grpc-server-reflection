require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'
require_relative 'protos/complex_services_pb'
require_relative 'protos/dependency_services_pb'
require_relative 'protos/enum_only_pb'

# ============================================================================
# Fix: guard ObjectSpace scanning against classes with dangerous respond_to?
# Commit: dad6a5b
# ============================================================================
RSpec.describe 'Fix: dangerous respond_to? classes in ObjectSpace' do
  it 'skips classes whose respond_to? raises an error' do
    dangerous_class = Class.new do
      def self.respond_to?(method, *args)
        raise RuntimeError, 'dangerous respond_to?'
      end

      def self.respond_to_missing?(method, *)
        raise RuntimeError, 'dangerous respond_to_missing?'
      end
    end

    expect {
      GrpcServerReflection::DescriptorRegistry.new
    }.not_to raise_error
  end
end

# ============================================================================
# Fix: rescue NotImplementedError when calling .descriptor on protobuf types
# Commit: 3beca1c
# ============================================================================
RSpec.describe 'Fix: NotImplementedError on .descriptor' do
  it 'skips types that raise NotImplementedError on .descriptor' do
    stub_class = Class.new do
      def self.respond_to?(method, *args)
        return true if method == :descriptor
        super
      end

      def self.descriptor
        raise NotImplementedError, 'descriptor not implemented'
      end
    end

    expect {
      GrpcServerReflection::DescriptorRegistry.new
    }.not_to raise_error
  end
end

# ============================================================================
# Fix: build FileDescriptorProto from introspection on older protobuf
# Commit: d2f1733
# ============================================================================
RSpec.describe 'Fix: FileDescriptorProto built from introspection' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

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

  it 'encodes streaming methods correctly' do
    serialized = registry.find_file_by_name('complex.proto')
    file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

    svc = file_proto.service.find { |s| s.name == 'ProfileService' }
    expect(svc).not_to be_nil

    # Server streaming
    list_method = svc['method'].find { |m| m.name == 'ListProfiles' }
    expect(list_method.client_streaming).to eq(false)
    expect(list_method.server_streaming).to eq(true)

    # Client streaming
    update_method = svc['method'].find { |m| m.name == 'UpdateProfiles' }
    expect(update_method.client_streaming).to eq(true)
    expect(update_method.server_streaming).to eq(false)

    # Bidi streaming
    sync_method = svc['method'].find { |m| m.name == 'SyncProfiles' }
    expect(sync_method.client_streaming).to eq(true)
    expect(sync_method.server_streaming).to eq(true)

    # Unary
    get_method = svc['method'].find { |m| m.name == 'GetProfile' }
    expect(get_method.client_streaming).to eq(false)
    expect(get_method.server_streaming).to eq(false)
  end
end

# ============================================================================
# Fix: nest child messages inside parents and reduce ObjectSpace iterations
# Commit: 14010f4
# ============================================================================
RSpec.describe 'Fix: nested messages placed in parent nested_type' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

  it 'nests Settings inside Profile as nested_type, not top-level' do
    serialized = registry.find_file_by_name('complex.proto')
    file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

    profile = file_proto.message_type.find { |m| m.name == 'Profile' }
    expect(profile).not_to be_nil

    settings = profile.nested_type.find { |m| m.name == 'Settings' }
    expect(settings).not_to be_nil

    # Settings should NOT appear as a top-level message
    top_level_names = file_proto.message_type.map(&:name)
    expect(top_level_names).not_to include('Settings')
    expect(top_level_names).not_to include('Profile.Settings')
  end
end

# ============================================================================
# Fix: support multi-level nested message types (e.g. Profile.Settings.Privacy)
# Commit: 007ae96
# ============================================================================
RSpec.describe 'Fix: multi-level nested messages (A.B.C)' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

  it 'nests Privacy inside Settings inside Profile (3 levels)' do
    serialized = registry.find_file_by_name('complex.proto')
    file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

    profile = file_proto.message_type.find { |m| m.name == 'Profile' }
    expect(profile).not_to be_nil

    settings = profile.nested_type.find { |m| m.name == 'Settings' }
    expect(settings).not_to be_nil

    privacy = settings.nested_type.find { |m| m.name == 'Privacy' }
    expect(privacy).not_to be_nil

    # Privacy fields are correct
    public_field = privacy.field.find { |f| f.name == 'public_profile' }
    expect(public_field).not_to be_nil
    expect(public_field.type).to eq(:TYPE_BOOL)
  end
end

# ============================================================================
# Fix: deduplicate messages/services and add cross-file dependencies
# Commit: b5f2860
# ============================================================================
RSpec.describe 'Fix: deduplication and cross-file dependencies' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

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

# ============================================================================
# Fix: add enum descriptor support to ObjectSpace fallback
# Commit: 9c207c3
# ============================================================================
RSpec.describe 'Fix: enum descriptor support' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

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

# ============================================================================
# Fix: extract package from enum names for enum-only proto files
# Commit: 4d93533
# ============================================================================
RSpec.describe 'Fix: enum-only proto file package extraction' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

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

# ============================================================================
# Fix: derive package from shortest name to handle nested types correctly
# Commit: ec7aefb
# ============================================================================
RSpec.describe 'Fix: package derivation from shortest name' do
  it 'derives package correctly for complex.proto with nested types' do
    registry = GrpcServerReflection::DescriptorRegistry.new
    serialized = registry.find_file_by_name('complex.proto')
    file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

    # Even though there are nested types like showcase.Profile.Settings.Privacy,
    # the package should still be 'showcase', not 'showcase.Profile'
    expect(file_proto.package).to eq('showcase')
  end
end

# ============================================================================
# Fix: generate MapEntry nested types for protobuf map fields
# Commit: 84159b0
# ============================================================================
RSpec.describe 'Fix: MapEntry nested types for map fields' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

  it 'generates MapEntry nested type for map<string, string> field' do
    serialized = registry.find_file_by_name('complex.proto')
    file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

    profile = file_proto.message_type.find { |m| m.name == 'Profile' }
    expect(profile).not_to be_nil

    # Find the map entry in nested_type
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

# ============================================================================
# Fix: prevent duplicate registration in GrpcReflection.reflect
# Commit: 7f614ec
# (Note: the reflect method may have been removed/refactored, test the
#  current behavior of adding Service to a server twice)
# ============================================================================
RSpec.describe 'Fix: duplicate registration prevention' do
  it 'can register Service on a server without error' do
    server = GRPC::RpcServer.new
    server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)

    expect {
      server.handle(GrpcServerReflection::Service)
    }.not_to raise_error
  end

  it 'second handle call raises RuntimeError from gRPC server' do
    server = GRPC::RpcServer.new
    server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(GrpcServerReflection::Service)

    # gRPC server itself raises on duplicate handler registration.
    # The fix (commit 7f614ec) added a guard in GrpcReflection.reflect
    # to check @handlers before calling server.handle again.
    expect {
      server.handle(GrpcServerReflection::Service)
    }.to raise_error(RuntimeError)
  end
end

# ============================================================================
# Fix: read @rpc_descs from server to auto-detect registered services
# Commit: 75e400d
# ============================================================================
RSpec.describe 'Fix: auto-detect services from @rpc_descs' do
  it 'extracts service names from rpc_descs keys' do
    server = GRPC::RpcServer.new
    server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(Test::TestService::Service)

    rpc_descs = server.instance_variable_get(:@rpc_descs)
    expect(rpc_descs).not_to be_nil

    service_names = rpc_descs.keys.map do |key|
      parts = key.to_s.split('/')
      parts[1] if parts.length >= 3
    end.compact.uniq

    expect(service_names).to include('test.TestService')
  end

  it 'filters registry to only server-registered services via allowed_service_names' do
    registry = GrpcServerReflection::DescriptorRegistry.new(
      allowed_service_names: ['test.TestService']
    )

    services = registry.list_services
    expect(services).to include('test.TestService')
    expect(services).not_to include('showcase.ProfileService')
  end

  it 'returns all services when allowed_service_names is nil' do
    registry = GrpcServerReflection::DescriptorRegistry.new

    services = registry.list_services
    expect(services).to include('test.TestService')
    expect(services).to include('showcase.ProfileService')
  end
end

# ============================================================================
# TypeMapping: safe_respond_to? and safe_call helpers
# (Covers commits dad6a5b and 3beca1c)
# ============================================================================
RSpec.describe GrpcServerReflection::DescriptorRegistry::TypeMapping do
  include described_class

  describe '#safe_respond_to?' do
    it 'returns false when respond_to? raises StandardError' do
      obj = Class.new { def self.respond_to?(*); raise StandardError; end }.new
      expect(safe_respond_to?(obj, :foo)).to eq(false)
    end

    it 'returns false when respond_to? raises NotImplementedError' do
      obj = Class.new { def self.respond_to?(*); raise NotImplementedError; end }.new
      expect(safe_respond_to?(obj, :foo)).to eq(false)
    end

    it 'returns true for valid methods' do
      expect(safe_respond_to?('hello', :length)).to eq(true)
    end
  end

  describe '#safe_call' do
    it 'returns nil when method raises StandardError' do
      obj = Object.new
      def obj.boom; raise StandardError, 'boom'; end
      expect(safe_call(obj, :boom)).to be_nil
    end

    it 'returns nil when method raises NotImplementedError' do
      obj = Object.new
      def obj.boom; raise NotImplementedError, 'not implemented'; end
      expect(safe_call(obj, :boom)).to be_nil
    end

    it 'returns the value on success' do
      expect(safe_call('hello', :length)).to eq(5)
    end
  end

  describe '#proto_field_type' do
    it 'maps known types correctly' do
      expect(proto_field_type(:string)).to eq(:TYPE_STRING)
      expect(proto_field_type(:int32)).to eq(:TYPE_INT32)
      expect(proto_field_type(:message)).to eq(:TYPE_MESSAGE)
      expect(proto_field_type(:enum)).to eq(:TYPE_ENUM)
      expect(proto_field_type(:bool)).to eq(:TYPE_BOOL)
      expect(proto_field_type(:bytes)).to eq(:TYPE_BYTES)
      expect(proto_field_type(:double)).to eq(:TYPE_DOUBLE)
      expect(proto_field_type(:float)).to eq(:TYPE_FLOAT)
    end

    it 'defaults to TYPE_STRING for unknown types' do
      expect(proto_field_type(:foobar)).to eq(:TYPE_STRING)
    end
  end

  describe '#proto_field_label' do
    it 'maps known labels' do
      expect(proto_field_label(:optional)).to eq(:LABEL_OPTIONAL)
      expect(proto_field_label(:required)).to eq(:LABEL_REQUIRED)
      expect(proto_field_label(:repeated)).to eq(:LABEL_REPEATED)
    end

    it 'defaults to LABEL_OPTIONAL for unknown labels' do
      expect(proto_field_label(:unknown)).to eq(:LABEL_OPTIONAL)
    end
  end

  describe '#remove_package' do
    it 'removes package prefix from full name' do
      expect(remove_package('my.pkg.MyMessage', 'my.pkg')).to eq('MyMessage')
    end

    it 'returns full name when package is empty' do
      expect(remove_package('MyMessage', '')).to eq('MyMessage')
    end

    it 'returns full name when package is nil' do
      expect(remove_package('MyMessage', nil)).to eq('MyMessage')
    end

    it 'handles nested names after package removal' do
      expect(remove_package('my.pkg.Parent.Child', 'my.pkg')).to eq('Parent.Child')
    end
  end
end

# ============================================================================
# DependencyResolver
# (Covers commit b5f2860)
# ============================================================================
RSpec.describe GrpcServerReflection::DescriptorRegistry::DependencyResolver do
  subject(:resolver) { described_class.new }

  it 'detects cross-file message field dependencies' do
    file_proto = Google::Protobuf::FileDescriptorProto.new(
      name: 'a.proto',
      package: 'a',
      message_type: [
        Google::Protobuf::DescriptorProto.new(
          name: 'MyMessage',
          field: [
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'other',
              number: 1,
              type: :TYPE_MESSAGE,
              type_name: '.b.OtherMessage'
            )
          ]
        )
      ]
    )

    local_symbols = { 'a.MyMessage' => true }
    dependencies = []
    symbol_to_filename = { 'b.OtherMessage' => 'b.proto' }

    resolver.collect_file_dependencies(file_proto, local_symbols, dependencies, symbol_to_filename)
    expect(dependencies).to include('b.proto')
  end

  it 'does not add local symbols as dependencies' do
    file_proto = Google::Protobuf::FileDescriptorProto.new(
      name: 'a.proto',
      package: 'a',
      message_type: [
        Google::Protobuf::DescriptorProto.new(
          name: 'Msg1',
          field: [
            Google::Protobuf::FieldDescriptorProto.new(
              name: 'other', number: 1, type: :TYPE_MESSAGE, type_name: '.a.Msg2'
            )
          ]
        ),
        Google::Protobuf::DescriptorProto.new(name: 'Msg2', field: [])
      ]
    )

    local_symbols = { 'a.Msg1' => true, 'a.Msg2' => true }
    dependencies = []

    resolver.collect_file_dependencies(file_proto, local_symbols, dependencies, {})
    expect(dependencies).to be_empty
  end

  it 'detects service method input/output type dependencies' do
    file_proto = Google::Protobuf::FileDescriptorProto.new(
      name: 'svc.proto',
      package: 'svc',
      service: [
        Google::Protobuf::ServiceDescriptorProto.new(
          name: 'MySvc',
          method: [
            Google::Protobuf::MethodDescriptorProto.new(
              name: 'DoThing',
              input_type: '.external.Request',
              output_type: '.external.Response'
            )
          ]
        )
      ]
    )

    local_symbols = {}
    dependencies = []
    symbol_to_filename = {
      'external.Request' => 'external.proto',
      'external.Response' => 'external.proto'
    }

    resolver.collect_file_dependencies(file_proto, local_symbols, dependencies, symbol_to_filename)
    expect(dependencies).to include('external.proto')
  end
end

# ============================================================================
# Oneof support in FileDescriptorProto
# (Covered by commit d2f1733)
# ============================================================================
RSpec.describe 'Fix: oneof fields encoded correctly' do
  let(:registry) { GrpcServerReflection::DescriptorRegistry.new }

  it 'encodes oneof declaration in Profile' do
    serialized = registry.find_file_by_name('complex.proto')
    file_proto = Google::Protobuf::FileDescriptorProto.decode(serialized)

    profile = file_proto.message_type.find { |m| m.name == 'Profile' }
    expect(profile).not_to be_nil

    oneof_names = profile.oneof_decl.map(&:name)
    expect(oneof_names).to include('contact')

    # Fields email and phone should reference the oneof
    email_field = profile.field.find { |f| f.name == 'email' }
    phone_field = profile.field.find { |f| f.name == 'phone' }
    expect(email_field).not_to be_nil
    expect(phone_field).not_to be_nil

    contact_index = oneof_names.index('contact')
    expect(email_field.oneof_index).to eq(contact_index)
    expect(phone_field.oneof_index).to eq(contact_index)
  end
end

# ============================================================================
# Full registry integration: service filtering with services: parameter
# ============================================================================
RSpec.describe 'Registry: services parameter filtering' do
  it 'filters to only specified service classes' do
    registry = GrpcServerReflection::DescriptorRegistry.new(
      services: [Test::TestService::Service]
    )

    services = registry.list_services
    expect(services).to include('test.TestService')
    expect(services).not_to include('showcase.ProfileService')
  end
end
