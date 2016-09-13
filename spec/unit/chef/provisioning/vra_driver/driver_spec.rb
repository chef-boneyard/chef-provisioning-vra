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
require 'chef/provisioning/vra_driver/driver'

module TestHelpers
  class ActionHandler
    def perform_action(_msg)
      raise 'perform_action called without a block' unless block_given?

      yield
    end
  end
end

describe Chef::Provisioning::VraDriver::Driver do
  let(:driver)          { Chef::Provisioning::VraDriver::Driver.new('vra:https://vra-test.corp.local', {}) }
  let(:action_handler)  { TestHelpers::ActionHandler.new }
  let(:machine_spec)    { double('machine_spec', name: 'test_name') }
  let(:machine_options) { double('machine_options') }
  let(:driver_version)  { Chef::Provisioning::VraDriver::VERSION }
  let(:config)          { {} }

  before do
    allow(action_handler).to receive(:report_progress)
    allow(driver).to receive(:config).and_return(config)
  end

  describe '#from_url' do
    it 'creates a new driver instance' do
      expect(Chef::Provisioning::VraDriver::Driver).to receive(:new).with('test_url', 'test_config')

      Chef::Provisioning::VraDriver::Driver.from_url('test_url', 'test_config')
    end
  end

  describe '#canonicalize_url' do
    it 'returns an array of the driver URL and config' do
      expect(Chef::Provisioning::VraDriver::Driver.canonicalize_url('test_url', 'test_config')).to eq(%w(test_url test_config))
    end
  end

  describe '#initialize' do
    it 'sets the base_url correctly' do
      expect(driver.base_url).to eq('https://vra-test.corp.local')
    end
  end

  describe '#allocate_machine' do
    let(:resource) { double('resource') }

    context 'when the resource exists' do
      it 'does not create a resource' do
        allow(driver).to receive(:resource_for).and_return(resource)
        expect(driver).not_to receive(:create_resource)

        driver.allocate_machine(action_handler, machine_spec, machine_options)
      end
    end

    context 'when the resource does not exist' do
      let(:bootstrap_options) { { catalog_id: 'test_catalog_id' } }
      let(:transport_options) { { is_windows: false } }
      let(:location) do
        {
          'driver_url'     => 'vra:https://vra-test.corp.local',
          'driver_version' => driver_version,
          'resource_id'    => 'test_id',
          'resource_name'  => 'test_name',
          'allocated_at'   => 'test_time',
          'is_windows'     => false
        }
      end

      before do
        allow(resource).to receive(:id).and_return('test_id')
        allow(resource).to receive(:name).and_return('test_name')
        allow(driver).to receive(:resource_for).and_return(nil)
        allow(driver).to receive(:bootstrap_options_for).and_return(bootstrap_options)
        allow(driver).to receive(:transport_options_for).and_return(transport_options)
        allow(driver).to receive(:create_resource).and_return(resource)
        allow(machine_spec).to receive(:location=)
        allow(Time).to receive_message_chain(:now, :utc).and_return('test_time')
      end

      it 'creates the resource' do
        expect(driver).to receive(:create_resource).with(action_handler, machine_spec, machine_options).and_return(resource)

        driver.allocate_machine(action_handler, machine_spec, machine_options)
      end

      it 'sets the location hash with identifying info for the resource' do
        expect(machine_spec).to receive(:location=).with(location)

        driver.allocate_machine(action_handler, machine_spec, machine_options)
      end
    end
  end

  describe '#ready_machine' do
    context 'when the resource does not exist' do
      it 'raises an exception' do
        allow(driver).to receive(:resource_for).and_return(nil)

        expect { driver.ready_machine(action_handler, machine_spec, machine_options) }.to raise_error(RuntimeError)
      end
    end

    context 'when the resource exists' do
      let(:resource)  { double('resource') }
      let(:transport) { double('transport') }
      let(:machine)   { double('machine') }

      before do
        allow(driver).to receive(:resource_for).and_return(resource)
        allow(driver).to receive(:power_on_machine)
        allow(driver).to receive(:transport_for).and_return(transport)
        allow(driver).to receive(:machine_for)
        allow(transport).to receive(:available?).and_return(true)
      end

      it 'powers on the machine' do
        expect(driver).to receive(:power_on_machine).with(action_handler, resource)

        driver.ready_machine(action_handler, machine_spec, machine_options)
      end

      it 'waits for the transport to be ready' do
        expect(transport).to receive(:available?).and_return(true)

        driver.ready_machine(action_handler, machine_spec, machine_options)
      end

      it 'returns the machine instance' do
        allow(driver).to receive(:machine_for).with(machine_spec, machine_options).and_return(machine)

        expect(driver.ready_machine(action_handler, machine_spec, machine_options)).to eq(machine)
      end
    end
  end

  describe '#stop_machine' do
    let(:resource) { double('resource') }

    it 'raises an exception if the resource does not exist' do
      allow(driver).to receive(:resource_for).and_return(nil)
      expect { driver.stop_machine(action_handler, machine_spec, machine_options) }.to raise_error(RuntimeError)
    end

    it 'powers off the machine if it exists' do
      allow(driver).to receive(:resource_for).and_return(resource)
      expect(driver).to receive(:power_off_machine).with(action_handler, resource)

      driver.stop_machine(action_handler, machine_spec, machine_options)
    end
  end

  describe '#destroy_machine' do
    context 'when the resource does not exist' do
      it 'does not attempt to destroy the resource' do
        allow(driver).to receive(:resource_for).and_return(nil)
        expect(action_handler).not_to receive(:perform_action)

        driver.destroy_machine(action_handler, machine_spec, machine_options)
      end
    end

    context 'when the resource exists' do
      let(:resource) { double('resource') }
      let(:request)  { double('request') }

      before do
        allow(driver).to receive(:resource_for).and_return(resource)
        allow(resource).to receive(:refresh)
        allow(resource).to receive(:destroy).and_return(request)
        allow(request).to receive(:refresh)
        allow(request).to receive(:completed?).and_return(true)
        allow(request).to receive(:failed?)
        allow(request).to receive(:completion_details)
      end

      it 'refreshes the resource object to get the available actions' do
        expect(resource).to receive(:refresh)

        driver.destroy_machine(action_handler, machine_spec, machine_options)
      end

      it 'submits a destroy request' do
        expect(resource).to receive(:destroy)

        driver.destroy_machine(action_handler, machine_spec, machine_options)
      end

      it 'refreshes the destroy request' do
        expect(request).to receive(:refresh)

        driver.destroy_machine(action_handler, machine_spec, machine_options)
      end

      it 'checks if the destroy request is completed' do
        expect(request).to receive(:completed?)

        driver.destroy_machine(action_handler, machine_spec, machine_options)
      end

      it 'raises an exception if the request failed' do
        expect(request).to receive(:failed?).and_return(true)

        expect { driver.destroy_machine(action_handler, machine_spec, machine_options) }.to raise_error(RuntimeError)
      end

      it 'does not raise an exception if the request succeeded' do
        expect(request).to receive(:failed?).and_return(false)

        expect { driver.destroy_machine(action_handler, machine_spec, machine_options) }.not_to raise_error
      end
    end
  end

  describe '#connect_to_machine' do
    let(:machine) { double('machine') }

    it 'returns a machine instance' do
      expect(driver).to receive(:machine_for).with(machine_spec, machine_options).and_return(machine)
      expect(driver.connect_to_machine(machine_spec, machine_options)).to eq(machine)
    end
  end

  describe '#description' do
    it 'returns a formatted description' do
      expect(driver.description(machine_spec)).to eq('X-Chef-Provisioning:test_name')
    end
  end

  describe '#resource_for' do
    context 'when no machine_spec location exists' do
      it 'returns nil' do
        allow(machine_spec).to receive(:location).and_return(nil)
        expect(driver.resource_for(machine_spec)).to eq(nil)
      end
    end

    context 'when machine_spec location exists' do
      let(:location)   { { 'resource_id' => 'test_id' } }
      let(:vra_client) { double('vra_client') }
      let(:resources)  { double('resources') }
      let(:resource)   { double('resource') }

      before do
        allow(machine_spec).to receive(:location).and_return(location)
        allow(driver).to receive(:vra_client).and_return(vra_client)
        allow(vra_client).to receive(:resources).and_return(resources)
        allow(resources).to receive(:by_id).and_return(resource)
      end

      it 'calls the resources API' do
        expect(resources).to receive(:by_id).with('test_id')

        driver.resource_for(machine_spec)
      end

      it 'returns the resource instance' do
        expect(driver.resource_for(machine_spec)).to eq(resource)
      end

      it 'returns nil if the resource is not found' do
        allow(resources).to receive(:by_id).and_raise(Vra::Exception::NotFound)

        expect(driver.resource_for(machine_spec)).to eq(nil)
      end
    end
  end

  describe '#create_resource' do
    let(:catalog_request)   { double('catalog_request') }
    let(:submitted_request) { double('submitted_request') }
    let(:server1)           { double('server1') }
    let(:server2)           { double('server2') }

    before do
      allow(driver).to receive(:catalog_request).and_return(catalog_request)
      allow(catalog_request).to receive(:submit).and_return(submitted_request)
      allow(submitted_request).to receive(:id)
      allow(submitted_request).to receive(:refresh)
      allow(submitted_request).to receive(:completed?).and_return(true)
      allow(submitted_request).to receive(:failed?)
      allow(submitted_request).to receive(:completion_details)
      allow(submitted_request).to receive(:resources).and_return([ server1 ])
      allow(server1).to receive(:vm?).and_return(true)
      allow(server2).to receive(:vm?).and_return(true)
    end

    it 'submits the catalog request' do
      expect(catalog_request).to receive(:submit).and_return(submitted_request)

      driver.create_resource(action_handler, machine_spec, machine_options)
    end

    it 'waits for the request to complete' do
      expect(submitted_request).to receive(:refresh)
      expect(submitted_request).to receive(:completed?).and_return(true)

      driver.create_resource(action_handler, machine_spec, machine_options)
    end

    it 'raises an exception if the request failed' do
      allow(submitted_request).to receive(:failed?).and_return(true)

      expect { driver.create_resource(action_handler, machine_spec, machine_options) }.to raise_error(RuntimeError)
    end

    it 'raises an exception if the request returned more than one VM' do
      allow(submitted_request).to receive(:resources).and_return([ server1, server2 ])

      expect { driver.create_resource(action_handler, machine_spec, machine_options) }.to raise_error(RuntimeError)
    end

    it 'raises an exception if the request returned no VMs' do
      allow(submitted_request).to receive(:resources).and_return([])

      expect { driver.create_resource(action_handler, machine_spec, machine_options) }.to raise_error(RuntimeError)
    end

    it 'returns the created resource' do
      expect(driver.create_resource(action_handler, machine_spec, machine_options)).to eq(server1)
    end
  end

  describe '#catalog_request' do
    let(:catalog_request) { double('catalog_request') }
    let(:vra_client)      { double('vra_client') }
    let(:catalog)         { double('catalog') }

    let(:bootstrap_options) do
      {
        catalog_id: 'test_id',
        cpus: 1,
        memory: 1024,
        requested_for: 'test_user',
        lease_days: 1,
        subtenant_id: 'test_subtenant',
        extra_parameters: {
          'key1' => { type: 'string', value: 'test_value1' },
          'key2' => { type: 'string', value: 'test_value2' }
        }
      }
    end

    before do
      allow(driver).to receive(:description).and_return('test_description')
      allow(driver).to receive(:vra_client).and_return(vra_client)
      allow(driver).to receive(:bootstrap_options_for).and_return(bootstrap_options)
      allow(vra_client).to receive(:catalog).and_return(catalog)
      allow(catalog).to receive(:request).and_return(catalog_request)

      [ :notes=, :cpus=, :memory=, :requested_for=, :lease_days=, :subtenant_id=, :set_parameter].each do |method|
        allow(catalog_request).to receive(method)
      end
    end

    it 'creates a catalog request via the API' do
      expect(catalog).to receive(:request).with('test_id').and_return(catalog_request)

      driver.catalog_request(machine_spec, machine_options)
    end

    it 'sets the required parameters' do
      expect(catalog_request).to receive(:notes=).with('test_description')
      expect(catalog_request).to receive(:cpus=).with(1)
      expect(catalog_request).to receive(:memory=).with(1024)
      expect(catalog_request).to receive(:requested_for=).with('test_user')

      driver.catalog_request(machine_spec, machine_options)
    end

    it 'sets optional and extra parameters when supplied' do
      expect(catalog_request).to receive(:lease_days=).with(1)
      expect(catalog_request).to receive(:subtenant_id=).with('test_subtenant')
      expect(catalog_request).to receive(:set_parameter).with('key1', 'string', 'test_value1')
      expect(catalog_request).to receive(:set_parameter).with('key2', 'string', 'test_value2')

      driver.catalog_request(machine_spec, machine_options)
    end

    it 'does not set optional and extra parameters when not supplied' do
      allow(driver).to receive(:bootstrap_options_for).and_return({})

      expect(catalog_request).not_to receive(:lease_days=)
      expect(catalog_request).not_to receive(:subtenant_id=)
      expect(catalog_request).not_to receive(:set_parameter)

      driver.catalog_request(machine_spec, machine_options)
    end

    it 'returns the catalog request instance' do
      expect(driver.catalog_request(machine_spec, machine_options)).to eq(catalog_request)
    end
  end

  describe '#power_on_machine' do
    let(:resource) { double('resource') }
    let(:request)  { double('request') }

    before do
      allow(resource).to receive(:id)
      allow(resource).to receive(:refresh)
      allow(resource).to receive(:machine_on?).and_return(false, true)
      allow(resource).to receive(:machine_turning_on?)
      allow(resource).to receive(:machine_in_provisioned_state?)
      allow(resource).to receive(:machine_status)
      allow(resource).to receive(:poweron).and_return(request)
      allow(request).to receive(:refresh)
      allow(request).to receive(:failed?)
      allow(request).to receive(:completion_details)
      allow(request).to receive(:completed?).and_return(true)
    end

    it 'refreshes the resource instance to ensure we have all resource actions' do
      expect(resource).to receive(:refresh)

      driver.power_on_machine(action_handler, resource)
    end

    it 'does not power on the machine if it is already on' do
      allow(resource).to receive(:machine_on?).and_return(true)
      expect(resource).not_to receive(:poweron)

      driver.power_on_machine(action_handler, resource)
    end

    it 'does not power on the machine if it is in the process of turning on' do
      allow(resource).to receive(:machine_turning_on?).and_return(true)
      expect(resource).not_to receive(:poweron)

      driver.power_on_machine(action_handler, resource)
    end

    it 'does not power on the machine if it is in a provisioned non-powered state' do
      allow(resource).to receive(:machine_in_provisioned_state?).and_return(true)
      expect(resource).not_to receive(:poweron)

      driver.power_on_machine(action_handler, resource)
    end

    it 'powers on the machine' do
      expect(resource).to receive(:poweron).and_return(request)

      driver.power_on_machine(action_handler, resource)
    end

    it 'refreshes the request and checks for its completion' do
      expect(request).to receive(:refresh)
      expect(request).to receive(:completed?).and_return(true)

      driver.power_on_machine(action_handler, resource)
    end

    it 'raises an exception if the power-on request failed' do
      allow(request).to receive(:failed?).and_return(true)

      expect { driver.power_on_machine(action_handler, resource) }.to raise_error(RuntimeError)
    end

    it 'waits for the resource to come online' do
      expect(resource).to receive(:refresh).twice
      expect(resource).to receive(:machine_on?).twice.and_return(false, true)

      driver.power_on_machine(action_handler, resource)
    end
  end

  describe '#poweroff_machine' do
    let(:resource) { double('resource') }
    let(:request)  { double('request') }

    before do
      allow(resource).to receive(:id)
      allow(resource).to receive(:refresh)
      allow(resource).to receive(:machine_off?).and_return(false, true)
      allow(resource).to receive(:machine_turning_off?)
      allow(resource).to receive(:shutdown).and_return(request)
      allow(resource).to receive(:poweroff).and_return(request)
      allow(request).to receive(:refresh)
      allow(request).to receive(:failed?)
      allow(request).to receive(:completion_details)
      allow(request).to receive(:completed?).and_return(true)
    end

    it 'refreshes the resource instance to ensure we have all resource actions' do
      expect(resource).to receive(:refresh)

      driver.power_off_machine(action_handler, resource)
    end

    it 'does not power off the machine if it is already off' do
      allow(resource).to receive(:machine_off?).and_return(true)
      expect(resource).not_to receive(:poweroff)

      driver.power_off_machine(action_handler, resource)
    end

    it 'does not power off the machine if it is in the process of turning off' do
      allow(resource).to receive(:machine_turning_off?).and_return(true)
      expect(resource).not_to receive(:poweroff)

      driver.power_off_machine(action_handler, resource)
    end

    it 'shuts down the machine' do
      expect(resource).to receive(:shutdown).and_return(request)

      driver.power_off_machine(action_handler, resource)
    end

    it 'powers off the machine if there is no shutdown action' do
      allow(resource).to receive(:shutdown).and_raise(Vra::Exception::NotFound)
      expect(resource).to receive(:poweroff).and_return(request)

      driver.power_off_machine(action_handler, resource)
    end

    it 'refreshes the request and checks for its completion' do
      expect(request).to receive(:refresh)
      expect(request).to receive(:completed?).and_return(true)

      driver.power_off_machine(action_handler, resource)
    end

    it 'raises an exception if the power-off request failed' do
      allow(request).to receive(:failed?).and_return(true)

      expect { driver.power_off_machine(action_handler, resource) }.to raise_error(RuntimeError)
    end

    it 'waits for the resource to power down' do
      expect(resource).to receive(:refresh).twice
      expect(resource).to receive(:machine_off?).twice.and_return(false, true)

      driver.power_off_machine(action_handler, resource)
    end
  end

  describe '#max_wait_time' do
    it 'returns the configured value in driver_options' do
      allow(driver).to receive(:driver_options).and_return(max_wait_time: 30)

      expect(driver.max_wait_time).to eq(30)
    end

    it 'returns the default value if there is no value in driver_options' do
      allow(driver).to receive(:driver_options).and_return({})

      expect(driver.max_wait_time).to eq(600)
    end
  end

  describe '#max_retries' do
    it 'returns the configured value in driver_options' do
      allow(driver).to receive(:driver_options).and_return(max_retries: 3)

      expect(driver.max_retries).to eq(3)
    end

    it 'returns the default value if there is no value in driver_options' do
      allow(driver).to receive(:driver_options).and_return({})

      expect(driver.max_retries).to eq(1)
    end
  end

  describe '#wait_for' do
    before do
      allow(driver).to receive(:sleep)
    end

    context 'when the block returns true immediately' do
      it 'does not retry' do
        expect(driver).not_to receive(:sleep)
        driver.wait_for(action_handler) { true }
      end
    end

    context 'when the block returns true after 3 tries' do
      it 'retries twice' do
        expect(driver).to receive(:sleep).twice

        @loop_count = 0
        driver.wait_for(action_handler) do
          @loop_count += 1
          @loop_count == 3
        end
      end
    end

    context 'when an exception is raised on first try but not second' do
      it 'does not raise an exception' do
        allow(driver).to receive(:max_retries).and_return(1)
        expect do
          driver.wait_for(action_handler) do
            if @raised_exception
              true
            else
              @raised_exception = true
              raise 'Raising exception on first loop'
            end
          end
        end.not_to raise_error
      end
    end

    context 'when an exception is raised on both tries' do
      it 'raises an exception' do
        allow(driver).to receive(:max_retries).and_return(1)
        expect { driver.wait_for(action_handler) { raise RuntimeError } }.to raise_error(RuntimeError)
      end
    end

    context 'when max_retries is 5 and the block raises exceptions' do
      it 'tries the block 6 times' do
        allow(driver).to receive(:max_retries).and_return(5)

        @loop_count = 0
        expect do
          driver.wait_for(action_handler) do
            @loop_count += 1
            raise RuntimeError
          end
        end.to raise_error(RuntimeError)
        expect(@loop_count).to eq(6)
      end
    end
  end

  describe '#username_for' do
    context 'when machine_spec reference entry exists' do
      it 'returns the correct username' do
        allow(machine_spec).to receive(:reference).and_return('username' => 'spec_username')
        allow(driver).to receive(:transport_options_for).and_return({})

        expect(driver.username_for(machine_spec, machine_options, 'default')).to eq('spec_username')
      end
    end

    context 'when machine_spec is nil and transport_options exists' do
      it 'returns the correct username' do
        allow(machine_spec).to receive(:reference).and_return({})
        allow(driver).to receive(:transport_options_for).and_return(username: 'transport_username')

        expect(driver.username_for(machine_spec, machine_options, 'default')).to eq('transport_username')
      end
    end

    context 'when machine_spec and transport_options are nil' do
      it 'returns the default username' do
        allow(machine_spec).to receive(:reference).and_return({})
        allow(driver).to receive(:transport_options_for).and_return({})

        expect(driver.username_for(machine_spec, machine_options, 'default')).to eq('default')
      end
    end
  end

  describe '#create_winrm_transport' do
    let(:resource)                    { double('resource') }
    let(:transport)                   { double('transport') }
    let(:transport_options_default)   { { password: 'test_password' } }
    let(:transport_options_plaintext) { { password: 'test_password', winrm_transport: 'plaintext' } }
    let(:transport_options_ssl)       { { password: 'test_password', winrm_transport: 'ssl', winrm_port: 22 } }
    let(:winrm_options)               { double('winrm_options') }

    it 'creates a proper transport instance and returns it' do
      allow(driver).to receive(:transport_options_for).and_return(transport_options_default)
      allow(driver).to receive(:remote_host_for).and_return('test-host')
      allow(driver).to receive(:winrm_options_for).and_return(winrm_options)
      allow(driver).to receive(:username_for).and_return('test_username')

      expect(Chef::Provisioning::Transport::WinRM).to receive(:new).with('http://test-host:5985/wsman',
                                                                         :negotiate,
                                                                         winrm_options,
                                                                         config).and_return(transport)

      expect(driver.create_winrm_transport(machine_spec, machine_options, resource)).to eq(transport)
    end

    it 'creates a proper transport instance with ssl on port 22 and returns it' do
      allow(driver).to receive(:transport_options_for).and_return(transport_options_ssl)
      allow(driver).to receive(:remote_host_for).and_return('test-host')
      allow(driver).to receive(:winrm_options_for).and_return(winrm_options)
      allow(driver).to receive(:username_for).and_return('test_username')

      expect(Chef::Provisioning::Transport::WinRM).to receive(:new).with('https://test-host:22/wsman',
                                                                         :ssl,
                                                                         winrm_options,
                                                                         config).and_return(transport)

      expect(driver.create_winrm_transport(machine_spec, machine_options, resource)).to eq(transport)
    end
  end

  describe '#winrm_transport_options_for' do
    context 'when the transport options are not defined' do
      let(:default_transport_options) { { winrm_transport: :negotiate, url: 'http://test-host:5985/wsman' } }
      it 'returns a default transport options hash' do
        expect(driver.winrm_transport_options_for('test-host', {})).to eq(default_transport_options)
      end
    end

    context 'when the transport options include ssl and a port' do
      let(:ssl_transport_options) { { winrm_transport: :ssl, url: 'https://test-host:22/wsman' } }
      it 'returns a transport with https and the right port' do
        expect(
          driver.winrm_transport_options_for(
            'test-host',
            winrm_transport: 'ssl',
            winrm_port: 22
          )
        ).to eq(ssl_transport_options)
      end
    end
  end

  describe '#winrm_options_for' do
    context 'when username contains backslashes' do
      let(:username) { '\\test-username' }
      let(:options) do
        {
          user: '\\test-username',
          pass: 'test-password',
          disable_sspi: true
        }
      end

      it 'returns a correct options hash' do
        expect(driver.winrm_options_for('\\test-username', 'test-password')).to eq(options)
      end
    end

    context 'when username does not contain backslashes' do
      let(:username) { 'test-username' }
      let(:options) do
        {
          user: 'test-username',
          pass: 'test-password',
          basic_auth_only: true
        }
      end

      it 'returns a correct options hash' do
        expect(driver.winrm_options_for('test-username', 'test-password')).to eq(options)
      end
    end
  end

  describe '#create_ssh_transport' do
    let(:transport)   { double('transport') }
    let(:ssh_options) { double('ssh_options') }
    let(:resource)    { double('resources') }
    let(:options)     { double('options') }

    it 'creates a proper transport instance and returns it' do
      allow(driver).to receive(:ssh_options_for).and_return(ssh_options)
      allow(driver).to receive(:remote_host_for).and_return('test_host')
      allow(driver).to receive(:username_for).and_return('test_username')
      allow(driver).to receive(:ssh_transport_options_for).and_return(options)

      expect(Chef::Provisioning::Transport::SSH).to receive(:new).with('test_host',
                                                                       'test_username',
                                                                       ssh_options,
                                                                       options,
                                                                       config).and_return(transport)

      expect(driver.create_ssh_transport(machine_spec, machine_options, resource)).to eq(transport)
    end
  end

  describe '#ssh_transport_options_for' do
    let(:username) { 'test-username' }

    before do
      allow(machine_spec).to receive(:reference).and_return({})
    end

    it 'sets ssh_pty_enable to true' do
      expect(driver.ssh_transport_options_for(machine_spec, username)[:ssh_pty_enable]).to eq(true)
    end

    it 'sets a prefix if sudo is enabled' do
      allow(driver).to receive(:use_sudo?).and_return(true)
      expect(driver.ssh_transport_options_for(machine_spec, username)[:prefix]).to eq('sudo ')
    end

    it 'does not set a prefix if sudo is disabled' do
      allow(driver).to receive(:use_sudo?).and_return(false)
      expect(driver.ssh_transport_options_for(machine_spec, username)[:prefix]).to eq(nil)
    end

    it 'sets a ssh_gateway if provided' do
      allow(machine_spec).to receive(:reference).and_return('ssh_gateway' => 'test_gateway')
      expect(driver.ssh_transport_options_for(machine_spec, username)[:ssh_gateway]).to eq('test_gateway')
    end

    it 'does not set a ssh_gateway if not provided' do
      allow(machine_spec).to receive(:reference).and_return({})
      expect(driver.ssh_transport_options_for(machine_spec, username)[:ssh_gateway]).to eq(nil)
    end
  end

  describe '#use_sudo?' do
    it 'returns true if sudo is set' do
      allow(machine_spec).to receive(:reference).and_return(sudo: true)
      expect(driver.use_sudo?(machine_spec, 'user')).to eq(true)
    end

    it 'returns true if sudo is unset but username is not root' do
      allow(machine_spec).to receive(:reference).and_return({})
      expect(driver.use_sudo?(machine_spec, 'non-root-user')).to eq(true)
    end

    it 'returns false if sudo is unset but username is root' do
      allow(machine_spec).to receive(:reference).and_return({})
      expect(driver.use_sudo?(machine_spec, 'root')).to eq(false)
    end
  end

  describe '#remote_host_for' do
    let(:resource) { double('resource') }

    it 'returns the name if there are no IP addresses' do
      allow(driver).to receive(:transport_options_for).and_return({})
      allow(resource).to receive(:ip_addresses).and_return([])
      allow(resource).to receive(:name).and_return('test-name')

      expect(driver.remote_host_for(machine_options, resource)).to eq('test-name')
    end

    it 'returns the name if there are IP addresses but use_hostname is set' do
      allow(driver).to receive(:transport_options_for).and_return(use_hostname: true)
      allow(resource).to receive(:ip_addresses).and_return([ '1.2.3.4' ])
      allow(resource).to receive(:name).and_return('test-name')

      expect(driver.remote_host_for(machine_options, resource)).to eq('test-name')
    end

    it 'returns the IP address by default' do
      allow(driver).to receive(:transport_options_for).and_return({})
      allow(resource).to receive(:ip_addresses).and_return([ '1.2.3.4' ])

      expect(driver.remote_host_for(machine_options, resource)).to eq('1.2.3.4')
    end
  end

  describe '#transport_for' do
    let(:resource)  { double('resource') }
    let(:transport) { double('transport') }

    before do
      allow(driver).to receive(:resource_for).and_return(resource)
    end

    it 'returns a windows tranport is the host is a windows host' do
      allow(driver).to receive(:windows?).and_return(true)
      expect(driver).to receive(:create_winrm_transport).and_return(transport)
      expect(driver.transport_for(machine_spec, machine_options)).to eq(transport)
    end

    it 'returns an ssh tranport is the host is not a windows host' do
      allow(driver).to receive(:windows?).and_return(false)
      expect(driver).to receive(:create_ssh_transport).and_return(transport)
      expect(driver.transport_for(machine_spec, machine_options)).to eq(transport)
    end
  end

  describe '#machine_for' do
    let(:machine) { double('machine') }

    before do
      allow(driver).to receive(:transport_for)
      allow(driver).to receive(:convergence_strategy_for)
    end

    it 'returns a windows machine instance if the host is a windows host' do
      allow(driver).to receive(:windows?).and_return(true)
      expect(Chef::Provisioning::Machine::WindowsMachine).to receive(:new).and_return(machine)
      expect(driver.machine_for(machine_spec, machine_options)).to eq(machine)
    end

    it 'returns a unix machine instance if the host is not a windows host' do
      allow(driver).to receive(:windows?).and_return(false)
      expect(Chef::Provisioning::Machine::UnixMachine).to receive(:new).and_return(machine)
      expect(driver.machine_for(machine_spec, machine_options)).to eq(machine)
    end
  end

  describe '#convergence_strategy_for' do
    let(:strategy)        { double('strategy') }
    let(:machine_options) { {} }

    it 'returns a InstallMsi strategy for a windows host' do
      allow(driver).to receive(:windows?).and_return(true)
      expect(Chef::Provisioning::ConvergenceStrategy::InstallMsi).to receive(:new).and_return(strategy)
      expect(driver.convergence_strategy_for(machine_spec, machine_options)).to eq(strategy)
    end

    it 'returns a InstallCached strategy for a unix host' do
      allow(driver).to receive(:windows?).and_return(false)
      expect(Chef::Provisioning::ConvergenceStrategy::InstallCached).to receive(:new).and_return(strategy)
      expect(driver.convergence_strategy_for(machine_spec, machine_options)).to eq(strategy)
    end
  end

  describe '#ssh_options_for' do
    let(:resource)          { double('resource') }
    let(:bootstrap_options) { { key_name: 'key_name' } }
    let(:transport_options) { {} }
    let(:machine_options)   { {} }
    let(:ssh_options)       { driver.ssh_options_for(machine_spec, machine_options, resource) }

    before do
      allow(driver).to receive(:get_private_key)
      allow(driver).to receive(:bootstrap_options_for).and_return(bootstrap_options)
      allow(driver).to receive(:transport_options_for).and_return(transport_options)
      allow(resource).to receive(:id)
    end

    it 'sets the host_key_alias' do
      allow(resource).to receive(:id).and_return('test_id')
      expect(ssh_options[:host_key_alias]).to eq('test_id.vra')
    end

    context 'when password is provided' do
      let(:transport_options) { { password: 'test_password' } }

      it 'sets the auth_methods to password' do
        expect(ssh_options[:auth_methods]).to eq([ 'password' ])
      end

      it 'sets keys_only to false' do
        expect(ssh_options[:keys_only]).to eq(false)
      end

      it 'sets the password' do
        expect(ssh_options[:password]).to eq('test_password')
      end
    end

    context 'when password is not provided' do
      let(:transport_options) { {} }

      it 'sets the auth_methods to publickey' do
        expect(ssh_options[:auth_methods]).to eq([ 'publickey' ])
      end

      it 'sets keys_only to true' do
        expect(ssh_options[:keys_only]).to eq(true)
      end
    end

    context 'when a key_path is provided' do
      let(:bootstrap_options) { { key_path: '/path/to/key' } }

      it 'reads the key at the key_path' do
        expect(IO).to receive(:read).with('/path/to/key').and_return('key_path_data')
        expect(ssh_options[:key_data]).to eq([ 'key_path_data' ])
      end
    end

    context 'when a key_name is provided' do
      let(:bootstrap_options) { { key_name: 'test_key' } }

      it 'reads the key specified by the name' do
        expect(driver).to receive(:get_private_key).with('test_key').and_return('key_name_data')
        expect(ssh_options[:key_data]).to eq([ 'key_name_data' ])
      end
    end

    context 'when no key_name or key_path are provided' do
      let(:bootstrap_options) { {} }

      it 'raises an exception' do
        expect { ssh_options }.to raise_error(RuntimeError)
      end
    end

    context 'when additional ssh options are provided' do
      let(:machine_options) { { ssh_options: { option1: 'value1', option2: 'value2' } } }
      it 'merges them correctly' do
        expect(ssh_options[:option1]).to eq('value1')
        expect(ssh_options[:option2]).to eq('value2')
      end
    end
  end

  describe '#vra_client' do
    let(:client) { double('client') }
    let(:driver_options) do
      {
        username:   'test_username',
        password:   'test_password',
        tenant:     'test_tenant',
        verify_ssl: true
      }
    end

    it 'returns a client instance' do
      allow(driver).to receive(:driver_options).and_return(driver_options)
      allow(driver).to receive(:base_url).and_return('test_url')
      expect(Vra::Client).to receive(:new).with(base_url: 'test_url',
                                                username: 'test_username',
                                                password: 'test_password',
                                                tenant:   'test_tenant',
                                                verify_ssl: true).and_return(client)

      expect(driver.vra_client).to eq(client)
    end
  end

  describe '#transport_options_for' do
    it 'returns the transport_options if provided' do
      expect(driver.transport_options_for(transport_options: 'opts')).to eq('opts')
    end

    it 'returns an empty hash if no options are provided' do
      expect(driver.transport_options_for({})).to eq({})
    end
  end

  describe '#bootstrap_options_for' do
    it 'returns the bootstrap_options if provided' do
      expect(driver.bootstrap_options_for(bootstrap_options: 'opts')).to eq('opts')
    end

    it 'returns an empty hash if no options are provided' do
      expect(driver.bootstrap_options_for({})).to eq({})
    end
  end

  describe '#windows?' do
    it 'returns true if is_windows is specified' do
      allow(machine_spec).to receive(:location).and_return('is_windows' => true)
      expect(driver.windows?(machine_spec)).to eq(true)
    end

    it 'returns false if is_windows is no specified' do
      allow(machine_spec).to receive(:location).and_return({})
      expect(driver.windows?(machine_spec)).to eq(false)
    end
  end
end
