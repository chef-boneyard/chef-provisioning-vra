# frozen_string_literal: true
#
# Author:: Chef Partner Engineering (<partnereng@chef.io>)
# Copyright:: Copyright (c) 2015 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/provisioning/driver'
require 'chef/provisioning/machine/windows_machine'
require 'chef/provisioning/machine/unix_machine'
require 'chef/provisioning/convergence_strategy/install_msi'
require 'chef/provisioning/convergence_strategy/install_cached'
require 'chef/provisioning/transport/winrm'
require 'chef/provisioning/transport/ssh'
require 'chef/provisioning/vra_driver/version'
require 'vra'

class Chef
  module Provisioning
    module VraDriver
      class Driver < Chef::Provisioning::Driver # rubocop:disable Metrics/ClassLength
        attr_reader :base_url

        def self.from_url(driver_url, config)
          Driver.new(driver_url, config)
        end

        def self.canonicalize_url(driver_url, config)
          [ driver_url, config ]
        end

        def initialize(driver_url, config)
          super

          _, @base_url = driver_url.split(':', 2)
          @resources = {}
        end

        def allocate_machine(action_handler, machine_spec, machine_options)
          resource = resource_for(machine_spec)
          return unless resource.nil?

          bootstrap_options = bootstrap_options_for(machine_options)
          transport_options = transport_options_for(machine_options)

          action_handler.perform_action("Create #{machine_spec.name} with catalog ID #{bootstrap_options[:catalog_id]}") do
            resource = create_resource(action_handler, machine_spec, machine_options)
          end

          machine_spec.location = {
            'driver_url'     => driver_url,
            'driver_version' => Chef::Provisioning::VraDriver::VERSION,
            'resource_id'    => resource.id,
            'resource_name'  => resource.name,
            'allocated_at'   => Time.now.utc.to_s,
            'is_windows'     => transport_options[:is_windows]
          }
        end

        def ready_machine(action_handler, machine_spec, machine_options)
          resource = resource_for(machine_spec)
          raise "Unable to locate machine for #{machine_spec.name}" if resource.nil?

          action_handler.report_progress("Powering on #{machine_spec.name} if needed")

          action_handler.perform_action("Power on machine #{machine_spec.name}") do
            power_on_machine(action_handler, resource)
          end

          action_handler.report_progress("Waiting for #{machine_spec.name} to be reachable")

          transport = transport_for(machine_spec, machine_options)
          action_handler.perform_action("Confirm #{machine_spec.name} is reachable") do
            wait_for(action_handler) { transport.available? }
          end

          machine_for(machine_spec, machine_options)
        end

        def stop_machine(action_handler, machine_spec, _machine_options)
          resource = resource_for(machine_spec)
          raise "Unable to locate machine for #{machine_spec.name}" if resource.nil?

          action_handler.report_progress("Submitting shutdown / power-off request for #{machine_spec.name}")

          action_handler.perform_action("Powering off machine #{machine_spec.name}") do
            power_off_machine(action_handler, resource)
          end
        end

        def destroy_machine(action_handler, machine_spec, _machine_options)
          resource = resource_for(machine_spec)
          return if resource.nil?

          action_handler.report_progress("Submitting destroy request for #{machine_spec.name}")

          action_handler.perform_action("Destroy machine #{machine_spec.name}") do
            resource.refresh

            destroy_req = resource.destroy
            wait_for(action_handler) do
              destroy_req.refresh
              destroy_req.completed?
            end

            raise "The vRA request failed: #{destroy_req.completion_details}" if destroy_req.failed?
          end
        end

        def connect_to_machine(machine_spec, machine_options)
          machine_for(machine_spec, machine_options)
        end

        def description(machine_spec)
          "X-Chef-Provisioning:#{machine_spec.name}"
        end

        def resource_for(machine_spec)
          return nil if machine_spec.location.nil?

          begin
            resource_id = machine_spec.location['resource_id']
            @resources[resource_id] ||= vra_client.resources.by_id(resource_id)
          rescue Vra::Exception::NotFound
            nil
          end
        end

        def create_resource(action_handler, machine_spec, machine_options)
          action_handler.report_progress("Submitting catalog request for #{machine_spec.name}")

          submitted_request = catalog_request(machine_spec, machine_options).submit
          action_handler.report_progress("Catalog request #{submitted_request.id} submitted.")

          wait_for(action_handler) do
            submitted_request.refresh
            submitted_request.completed?
          end

          raise "The vRA request failed: #{submitted_request.completion_details}" if submitted_request.failed?

          servers = submitted_request.resources.select(&:vm?)
          raise 'The vRA request created more than one server. The catalog blueprint should only return one.' if servers.size > 1
          raise 'the vRA request did not create any servers.' if servers.size.zero?

          servers.first
        end

        def catalog_request(machine_spec, machine_options)
          bootstrap_options = bootstrap_options_for(machine_options)
          catalog_request = vra_client.catalog.request(bootstrap_options[:catalog_id])

          catalog_request.notes         = description(machine_spec)
          catalog_request.cpus          = bootstrap_options[:cpus]
          catalog_request.memory        = bootstrap_options[:memory]
          catalog_request.requested_for = bootstrap_options[:requested_for]
          catalog_request.lease_days    = bootstrap_options[:lease_days]   unless bootstrap_options[:lease_days].nil?
          catalog_request.subtenant_id  = bootstrap_options[:subtenant_id] unless bootstrap_options[:subtenant_id].nil?

          if bootstrap_options.key?(:extra_parameters) && bootstrap_options[:extra_parameters].respond_to?(:each)
            bootstrap_options[:extra_parameters].each do |key, value_data|
              catalog_request.set_parameter(key, value_data[:type], value_data[:value])
            end
          end

          catalog_request
        end

        def power_on_machine(action_handler, resource)
          resource.refresh
          return if resource.machine_on? || resource.machine_turning_on? || resource.machine_in_provisioned_state?

          action_handler.report_progress("Machine status is #{resource.machine_status}. " \
            "Submitting power-on request for resource #{resource.id}")
          power_on_req = resource.poweron
          wait_for(action_handler) do
            power_on_req.refresh
            power_on_req.completed?
          end

          raise "The vRA request failed: #{power_on_req.completion_details}" if power_on_req.failed?

          action_handler.report_progress("Waiting for resource #{resource.id} to be powered on")
          wait_for(action_handler) do
            resource.refresh
            resource.machine_on?
          end
        end

        def power_off_machine(action_handler, resource)
          resource.refresh
          return if resource.machine_off? || resource.machine_turning_off?

          action_handler.report_progress("Submitting shutdown/power-off request for resource #{resource.id}")
          begin
            power_off_req = resource.shutdown
          rescue Vra::Exception::NotFound
            power_off_req = resource.poweroff
          end

          wait_for(action_handler) do
            power_off_req.refresh
            power_off_req.completed?
          end

          raise "The vRA request failed: #{power_off_req.completion_details}" if power_off_req.failed?

          action_handler.report_progress("Waiting for resource #{resource.id} to be powered off")
          wait_for(action_handler) do
            resource.refresh
            resource.machine_off?
          end
        end

        def max_wait_time
          driver_options.fetch(:max_wait_time, 600).to_i
        end

        def max_retries
          driver_options.fetch(:max_retries, 1).to_i
        end

        def wait_for(action_handler)
          sleep_time    = 5
          start_time    = Time.now.utc.to_i
          try           = 0

          Timeout.timeout(max_wait_time) do
            loop do
              begin
                return if yield == true
              rescue => e
                action_handler.report_progress("Error encountered: #{e.class} - #{e.message}")

                try += 1
                if try > max_retries
                  action_handler.report_progress('Retries exceeded, aborting...')
                  raise
                end
              end

              time_elapsed = Time.now.utc.to_i - start_time
              action_handler.report_progress("been waiting #{time_elapsed}/#{max_wait_time} seconds" \
                " -- sleeping #{sleep_time} seconds")
              sleep sleep_time
            end
          end
        end

        def username_for(machine_spec, machine_options, default_username)
          transport_options = transport_options_for(machine_options)

          machine_spec.reference['username'] || transport_options[:username] || default_username
        end

        def create_winrm_transport(machine_spec, machine_options, resource)
          transport_options = transport_options_for(machine_options)
          remote_host       = remote_host_for(machine_options, resource)
          username          = username_for(machine_spec, machine_options, 'Administrator')
          winrm_transport   = transport_options[:winrm_transport].nil? ? :negotiate : transport_options[:winrm_transport].to_sym
          Chef::Log.debug("WinRM transport: #{winrm_transport}")
          winrm_port        = transport_options[:winrm_port] unless transport_options[:winrm_port].nil?
          winrm_port ||= winrm_transport == :plaintext || winrm_transport == :negotiate ? 5985 : 5986
          scheme            = winrm_transport == :plaintext || winrm_transport == :negotiate ? 'http' : 'https'
          url               = "#{scheme}://#{remote_host}:#{winrm_port}/wsman"
          winrm_options     = winrm_options_for(username, transport_options[:password])

          Chef::Log.debug("Creating WinRM connection to #{url}")
          Chef::Provisioning::Transport::WinRM.new(url, :plaintext, winrm_options, config)
        end

        def winrm_options_for(username, password)
          auth_type_opt = username.include?('\\') ? :disable_sspi : :basic_auth_only

          {
            user: username,
            pass: password,
            auth_type_opt => true
          }
        end

        def create_ssh_transport(machine_spec, machine_options, resource)
          ssh_options = ssh_options_for(machine_spec, machine_options, resource)
          remote_host = remote_host_for(machine_options, resource)
          username    = username_for(machine_spec, machine_options, 'root')
          options     = ssh_transport_options_for(machine_spec, username)

          Chef::Provisioning::Transport::SSH.new(remote_host, username, ssh_options, options, config)
        end

        def ssh_transport_options_for(machine_spec, username)
          options = {}
          options[:prefix]         = 'sudo ' if use_sudo?(machine_spec, username)
          options[:ssh_pty_enable] = true
          options[:ssh_gateway]    = machine_spec.reference['ssh_gateway'] if machine_spec.reference['ssh_gateway']

          options
        end

        def use_sudo?(machine_spec, username)
          machine_spec.reference[:sudo] || (!machine_spec.reference.key?(:sudo) && username != 'root')
        end

        def remote_host_for(machine_options, resource)
          transport_options = transport_options_for(machine_options)
          if resource.ip_addresses.empty? || transport_options[:use_hostname]
            resource.name
          else
            resource.ip_addresses.first
          end
        end

        def transport_for(machine_spec, machine_options)
          resource = resource_for(machine_spec)

          if windows?(machine_spec)
            create_winrm_transport(machine_spec, machine_options, resource)
          else
            create_ssh_transport(machine_spec, machine_options, resource)
          end
        end

        def machine_for(machine_spec, machine_options)
          if windows?(machine_spec)
            Chef::Provisioning::Machine::WindowsMachine.new(machine_spec,
                                                            transport_for(machine_spec, machine_options),
                                                            convergence_strategy_for(machine_spec, machine_options))
          else
            Chef::Provisioning::Machine::UnixMachine.new(machine_spec,
                                                         transport_for(machine_spec, machine_options),
                                                         convergence_strategy_for(machine_spec, machine_options))
          end
        end

        def convergence_strategy_for(machine_spec, machine_options)
          if windows?(machine_spec)
            Chef::Provisioning::ConvergenceStrategy::InstallMsi.new(machine_options[:convergence_options], config)
          else
            Chef::Provisioning::ConvergenceStrategy::InstallCached.new(machine_options[:convergence_options], config)
          end
        end

        def ssh_options_for(machine_spec, machine_options, resource)
          bootstrap_options = bootstrap_options_for(machine_options)
          transport_options = transport_options_for(machine_options)

          if transport_options.key?(:password)
            ssh_options = {
              auth_methods: [ 'password' ],
              keys_only:    false,
              password:     transport_options[:password]
            }
          else
            ssh_options = {
              auth_methods: [ 'publickey' ],
              keys_only:    true
            }

            if bootstrap_options[:key_path]
              ssh_options[:key_data] = [ IO.read(bootstrap_options[:key_path]) ]
            elsif bootstrap_options[:key_name]
              ssh_options[:key_data] = [ get_private_key(bootstrap_options[:key_name]) ]
            else
              raise "No key found to connect to #{machine_spec.name}" \
                " - set a key_path or key_name in the machine's bootstrap_options"
            end
          end

          ssh_options[:host_key_alias] = "#{resource.id}.vra"
          ssh_options.merge(machine_options[:ssh_options] || {})
        end

        def vra_client
          @vra_client ||= ::Vra::Client.new(
            base_url:   base_url,
            username:   driver_options[:username],
            password:   driver_options[:password],
            tenant:     driver_options[:tenant],
            verify_ssl: driver_options[:verify_ssl]
          )
        end

        def transport_options_for(machine_options)
          machine_options.key?(:transport_options) ? machine_options[:transport_options] : {}
        end

        def bootstrap_options_for(machine_options)
          machine_options.key?(:bootstrap_options) ? machine_options[:bootstrap_options] : {}
        end

        def windows?(machine_spec)
          machine_spec.location['is_windows'] ? true : false
        end
      end
    end
  end
end
