require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'

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