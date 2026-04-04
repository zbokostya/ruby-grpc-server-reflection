# grpc-server-reflection

Ruby gem implementing the [gRPC Server Reflection Protocol v1](https://github.com/grpc/grpc/blob/master/doc/server-reflection.md). Enables tools like `grpcurl`, `grpcui`, and Postman to introspect your gRPC services without `.proto` files.

## Installation

Add to your Gemfile:

```ruby
gem 'grpc-server-reflection'
```

## Usage

```ruby
require 'grpc_server_reflection'

server = GRPC::RpcServer.new
server.add_http2_port('0.0.0.0:50051', :this_port_is_insecure)
server.handle(MyApp::GreeterService)
server.handle(GrpcServerReflection::Service)  # Add reflection
server.run
```

Then use grpcurl to test:

```bash
grpcurl -plaintext localhost:50051 list
```

## Requirements

- Ruby >= 2.7
- grpc gem (~> 1.0)
- google-protobuf gem (~> 3.0)

## License

MIT
