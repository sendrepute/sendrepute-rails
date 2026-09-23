# frozen_string_literal: true

require_relative "lib/sendrepute/rails/version"

Gem::Specification.new do |spec|
  spec.name = "sendrepute-rails"
  spec.version = SendRepute::Rails::VERSION
  spec.authors = ["SendRepute"]
  spec.summary = "Opt-in SendRepute pre-send checks for Rails Action Mailer"
  spec.homepage = "https://www.sendrepute.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "LICENSE", "MANIFEST.txt", "README.md", "SECURITY.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionmailer", ">= 7.1", "< 8.0"
end
