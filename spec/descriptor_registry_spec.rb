require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'

RSpec.describe GrpcReflection::DescriptorRegistry do
  subject(:registry) { described_class.new }

  describe '#list_services' do
    it 'returns fully-qualified service names from loaded descriptors' do
      services = registry.list_services
      expect(services).to include('test.TestService')
    end
  end
end
