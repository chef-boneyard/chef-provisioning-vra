# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'chef/provisioning/vra_driver/version'

Gem::Specification.new do |spec|
  spec.name          = 'chef-provisioning-vra'
  spec.version       = Chef::Provisioning::VraDriver::VERSION
  spec.authors       = ['Chef Partner Engineering']
  spec.email         = ['partnereng@chef.io']
  spec.summary       = 'A Chef Provisioning driver for VMware vRealize Automation (vRA)'
  spec.description   = spec.summary
  spec.homepage      = 'https://github.com/chef-partners/chef-provisioning-vra'
  spec.license       = 'Apache 2.0'

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = []
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_dependency 'chef-provisioning'
  spec.add_dependency 'vmware-vra',            '~> 1.3'

  spec.add_development_dependency 'chef',      '>= 12'
  spec.add_development_dependency 'bundler',   '~> 1.7'
  spec.add_development_dependency 'rake',      '~> 10.0'
  spec.add_development_dependency 'rspec',     '~> 3.2'
  spec.add_development_dependency 'rubocop',   '~> 0.35'
end
