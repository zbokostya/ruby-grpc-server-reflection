lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'grpc_server_reflection/version'

Gem::Specification.new do |spec|
  spec.name          = 'grpc-server-reflection'
  spec.version       = GrpcServerReflection::VERSION
  spec.authors       = ['zbokostya']
  spec.summary       = 'gRPC Server Reflection Protocol v1 for Ruby'
  spec.description   = 'Implements the gRPC Server Reflection Protocol v1, enabling tools like grpcurl and Postman to introspect gRPC services.'
  spec.homepage      = 'https://github.com/zbokostya/ruby-grpc-server-reflection'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 2.7'

  spec.files         = Dir['lib/**/*', 'grpc/**/*', 'LICENSE', 'README.md']
  spec.require_paths = ['lib', '.']

  spec.add_dependency 'grpc', '~> 1.0'
  spec.add_dependency 'google-protobuf', '~> 3.0'

  spec.add_development_dependency 'bundler', '~> 2.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'grpc-tools', '~> 1.0'
end
