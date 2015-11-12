# chef-provisioning-vra

Chef Provisioning driver for vRealize Automation

## Configuring and Usage

First, configure Chef Provisioning with your vRA server and authentication information. One option is to place a `driver_options` section in your `knife.rb`:

```ruby
driver_options username: 'my@email.address',
               password: 's00pers33cret',
               tenant: 'vsphere.local',
               verify_ssl: false,
               max_wait_time: 1800
```

`username`, `password`, and `tenant` are required.

`verify_ssl` is optional and defaults to true. If you cannot configure your client or server with trusted certificates, you can set this to false.

`max_wait_time` is the number of seconds to wait for any operation where a request was submitted to vRA and Chef Provisioning must wait for it to complete.  By default, this is 600.

Secondly, in your recipe, configure your bootstrap and transport options for your machine(s).  You can do this using the `with_machine_options` method, or you can pass it directly to each machine's `machine_options` property:

```ruby
machine_options = {
  bootstrap_options: {
    catalog_id: '7bd5f299-8c34-41f6-b63f-c2ac410ee0b6',
    subtenant_id: 'my_subtenant_uuid',
    cpus: 1,
    memory: 1024,
    requested_for: 'my@email.address',
    lease_days: 30,
    key_path: '/path/to/ssh/key'
  },
  transport_options: {
    is_windows: false,
    username: 'ubuntu',
  }
}
```

### Driver URL

The driver URL should be `vra:https://my-vra-host.com`. Like any other Chef Provisioning driver, you may set this a variety of ways, including the `with_driver` method in your recipe:

```ruby
with_driver 'vra:https://vra.corp.local' do
  ... my machines here ...
end
```

### Bootstrap Options

The following properties are required:

 * catalog_id
 * cpus
 * memory
 * requested_for

`subtenant_id` is required if your catalog item is a global item and not tied to a specific business group / subtenant.

If you wish to use SSH keys, you must specify a `key_path` or `key_name`.  Failure to specify one of those will cause an error.  If you wish to use password authentication, specify a password in the transport_options.

You may specify additional extra parameters to be passed to the vRA API using the `extra_parameters` property hash:

```ruby
bootstrap_options: {
  extra_parameters: {
    parameter1_name: {
      type: 'string',
      value: 'my value'
    },
    parameter2_name: {
      type: 'integer',
      value: 2
    }
  }
}
```

### Transport Options

All transport options are optional.

 * `is_windows`: set this to `true` if you are creating a windows machine.  Unfortunately, you must set this manually as vRA does not offer a consistent method for determining this through the API.
 * `username`: set this to the SSH or WinRM user to use when logging in.  Defaults to `root` on Unix and `Administrator` on Windows.  On Unix, if a non-root user is supplied, Chef Provisioning will attempt to use sudo to gain the required privileges.
 * `password`:
   * *Windows*: required.  Set to the user's password to use to log in via WinRM.
   * *Unix*: optional.  If set, SSH key authentication will not be used.

### Resources

Only the `machine` resource is supported.

## License and Authors

Author:: Chef Partner Engineering (<partnereng@chef.io>)

Copyright:: Copyright (c) 2015 Chef Software, Inc.

License:: Apache License, Version 2.0

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. You may obtain a copy of the License at

```
http://www.apache.org/licenses/LICENSE-2.0
```

Unless required by applicable law or agreed to in writing, software distributed under the
License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing permissions
and limitations under the License.

## Contributing

1. Fork it ( https://github.com/[my-github-username]/vmware-vra-gem/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
