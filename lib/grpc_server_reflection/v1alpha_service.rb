module GrpcServerReflection
  class V1AlphaService < Grpc::Reflection::V1alpha::ServerReflection::Service
    include RequestHandler

    private

    def proto_module
      Grpc::Reflection::V1alpha
    end
  end
end
