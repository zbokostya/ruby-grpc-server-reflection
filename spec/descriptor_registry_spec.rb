require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'

RSpec.describe GrpcServerReflection::DescriptorRegistry do
  subject(:registry) { described_class.new }

  describe '#list_services' do
    it 'returns fully-qualified service names from loaded descriptors' do
      services = registry.list_services
      expect(services).to include('test.TestService')
    end
  end

  describe '#find_file_by_name' do
    it 'returns serialized FileDescriptorProto for known file' do
      result = registry.find_file_by_name('test.proto')
      expect(result).not_to be_nil
    end

    it 'returns nil for unknown file' do
      expect(registry.find_file_by_name('nonexistent.proto')).to be_nil
    end
  end

  describe '#find_file_by_symbol' do
    it 'finds file by service name' do
      result = registry.find_file_by_symbol('test.TestService')
      expect(result).not_to be_nil
    end

    it 'finds file by message name' do
      result = registry.find_file_by_symbol('test.TestRequest')
      expect(result).not_to be_nil
    end

    it 'returns nil for unknown symbol' do
      expect(registry.find_file_by_symbol('unknown.Symbol')).to be_nil
    end
  end

  describe '#file_descriptors_with_dependencies' do
    it 'returns the file and its transitive dependencies as serialized protos' do
      results = registry.file_descriptors_with_dependencies('test.proto')
      expect(results).to be_an(Array)
      expect(results.length).to be >= 1
    end

    it 'returns empty array for unknown file' do
      expect(registry.file_descriptors_with_dependencies('nonexistent.proto')).to eq([])
    end
  end

  describe '#find_extension_numbers' do
    it 'returns empty array for type with no extensions' do
      expect(registry.find_extension_numbers('test.TestRequest')).to eq([])
    end
  end
end
