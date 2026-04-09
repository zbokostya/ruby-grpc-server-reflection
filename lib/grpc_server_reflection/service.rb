module GrpcServerReflection
  class Service < Grpc::Reflection::V1::ServerReflection::Service
    include RequestHandler

    private

    def proto_module
      Grpc::Reflection::V1
    end
  end
end
