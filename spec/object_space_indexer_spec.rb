require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'
require_relative 'protos/complex_services_pb'

RSpec.describe GrpcServerReflection::DescriptorRegistry::ObjectSpaceIndexer do
  describe 'dangerous respond_to? classes in ObjectSpace' do
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

  describe 'NotImplementedError on .descriptor' do
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
end