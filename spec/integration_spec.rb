require 'spec_helper'
require_relative 'protos/test_services_pb'

RSpec.describe 'Integration: Reflection Service', :integration do
  it 'can be added to a GRPC server and responds to list_services' do
    server = GRPC::RpcServer.new
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(GrpcReflection::Service)

    thread = Thread.new { server.run }
    sleep 0.5

    begin
      stub = Grpc::Reflection::V1::ServerReflection::Stub.new(
        "127.0.0.1:#{port}",
        :this_channel_is_insecure
      )

      request = Grpc::Reflection::V1::ServerReflectionRequest.new(list_services: '')
      responses = stub.server_reflection_info([request])

      response = responses.first
      service_names = response.list_services_response.service.map(&:name)
      expect(service_names).to include('grpc.reflection.v1.ServerReflection')
    ensure
      server.stop
      thread.join(5)
    end
  end
end
