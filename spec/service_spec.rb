require 'spec_helper'
require_relative 'protos/test_services_pb'

RSpec.describe GrpcReflection::Service do
  let(:service) { described_class.new }

  def make_request(attrs = {})
    Grpc::Reflection::V1::ServerReflectionRequest.new(attrs)
  end

  def call_with_requests(*requests)
    responses = []
    output_enum = service.server_reflection_info(requests.each, nil)
    output_enum.each { |resp| responses << resp }
    responses
  end

  describe 'list_services' do
    it 'returns all registered service names' do
      request = make_request(list_services: '')
      responses = call_with_requests(request)

      expect(responses.length).to eq(1)
      response = responses.first

      service_names = response.list_services_response.service.map(&:name)
      expect(service_names).to include('test.TestService')
    end
  end

  describe 'file_by_filename' do
    it 'returns file descriptor for known file' do
      request = make_request(file_by_filename: 'test.proto')
      responses = call_with_requests(request)

      expect(responses.length).to eq(1)
      response = responses.first
      expect(response.file_descriptor_response).not_to be_nil
    end

    it 'returns error for unknown file' do
      request = make_request(file_by_filename: 'nonexistent.proto')
      responses = call_with_requests(request)

      expect(responses.first.error_response.error_code).to eq(GRPC::Core::StatusCodes::NOT_FOUND)
    end
  end

  describe 'file_containing_symbol' do
    it 'returns file descriptor for known symbol' do
      request = make_request(file_containing_symbol: 'test.TestService')
      responses = call_with_requests(request)

      expect(responses.length).to eq(1)
      expect(responses.first.file_descriptor_response).not_to be_nil
    end

    it 'returns error for unknown symbol' do
      request = make_request(file_containing_symbol: 'unknown.Symbol')
      responses = call_with_requests(request)

      expect(responses.first.error_response.error_code).to eq(GRPC::Core::StatusCodes::NOT_FOUND)
    end
  end

  describe 'all_extension_numbers_of_type' do
    it 'returns extension numbers response' do
      request = make_request(all_extension_numbers_of_type: 'test.TestRequest')
      responses = call_with_requests(request)

      expect(responses.length).to eq(1)
      ext_response = responses.first.all_extension_numbers_response
      expect(ext_response.base_type_name).to eq('test.TestRequest')
      expect(ext_response.extension_number).to eq([])
    end
  end

  describe 'multiple requests in stream' do
    it 'handles multiple requests and returns matching responses' do
      req1 = make_request(list_services: '')
      req2 = make_request(file_by_filename: 'test.proto')
      responses = call_with_requests(req1, req2)

      expect(responses.length).to eq(2)
      expect(responses[0].list_services_response).not_to be_nil
      expect(responses[1].file_descriptor_response).not_to be_nil
    end
  end
end
