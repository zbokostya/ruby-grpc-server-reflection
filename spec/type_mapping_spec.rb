require 'spec_helper'
$LOAD_PATH.unshift(File.join(__dir__, 'protos')) unless $LOAD_PATH.include?(File.join(__dir__, 'protos'))
require_relative 'protos/test_services_pb'

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