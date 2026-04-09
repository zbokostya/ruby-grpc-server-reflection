require 'grpc'
require 'google/protobuf'
require 'grpc/reflection/v1/reflection_services_pb'
require 'grpc/reflection/v1alpha/reflection_services_pb'
require_relative 'grpc_server_reflection/version'
require_relative 'grpc_server_reflection/descriptor_registry'
require_relative 'grpc_server_reflection/request_handler'
require_relative 'grpc_server_reflection/service'
require_relative 'grpc_server_reflection/v1alpha_service'

module GrpcServerReflection
  class << self
    # Manually set which services to reflect.
    # If not set, auto-detects from the server's registered handlers.
    #
    #   GrpcServerReflection.services = [MyService, OtherService]
    #   s.handle(GrpcServerReflection::Service)
    #
    attr_accessor :services
  end
end
