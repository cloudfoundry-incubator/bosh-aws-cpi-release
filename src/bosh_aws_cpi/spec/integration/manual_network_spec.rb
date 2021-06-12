require 'integration/spec_helper'
require 'bosh/cpi/compatibility_helpers/delete_vm'
require 'tempfile'
require 'bosh/cpi/logger'
require 'cloud'
require 'ipaddr'

describe Bosh::AwsCloud::CloudV1 do
  before(:all) do
    @elb_id             = ENV.fetch('BOSH_AWS_ELB_ID')
    @target_group_name  = ENV.fetch('BOSH_AWS_TARGET_GROUP_NAME')
    @manual_subnet_id   = ENV.fetch('BOSH_AWS_MANUAL_SUBNET_ID')

    @ip_semaphore = Mutex.new
    @already_used = []
  end

  let(:instance_type_with_ephemeral)      { ENV.fetch('BOSH_AWS_INSTANCE_TYPE', 'm3.medium') }
  let(:instance_type_with_ephemeral_nvme) { ENV.fetch('BOSH_AWS_INSTANCE_TYPE_EPHEMERAL_NVME', 'i3.large') }
  let(:instance_type_without_ephemeral)   { ENV.fetch('BOSH_AWS_INSTANCE_TYPE_WITHOUT_EPHEMERAL', 't2.small') }
  let(:instance_type_ipv6)                { 't2.small' } # "IPv6 is not supported for the instance type 'm3.medium'"
  let(:ami)                               { hvm_ami }
  let(:hvm_ami)                           { ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-9c91b7fc') }
  let(:pv_ami)                            { ENV.fetch('BOSH_AWS_PV_IMAGE_ID', 'ami-3f71225f') }
  let(:windows_ami)                       { ENV.fetch('BOSH_AWS_WINDOWS_IMAGE_ID', 'ami-f8dfd698') }
  let(:eip)                               { ENV.fetch('BOSH_AWS_ELASTIC_IP') }
  let(:ipv6_ip)                           { ENV.fetch('BOSH_AWS_MANUAL_IPV6_IP') }
  let(:instance_type) { instance_type_with_ephemeral }
  let(:user_defined_tags) { { custom1: 'custom_value1', custom2: 'custom_value2' } }
  let(:vm_metadata) { { deployment: 'deployment', job: 'cpi_spec', index: '0', delete_me: 'please' }.merge(user_defined_tags) }
  let(:disks) { [] }
  let(:network_spec) { {} }
  let(:vm_type) { { 'instance_type' => instance_type, 'availability_zone' => @subnet_zone } }
  let(:security_groups) { get_security_group_ids }
  let(:registry) { instance_double(Bosh::Cpi::RegistryClient).as_null_object }
  let(:security_groups) { get_security_group_ids }
  let(:mock_cpi_api_version) { 2 }

  let(:aws_config) do
    {
      'region' => @region,
      'default_key_name' => @default_key_name,
      'default_security_groups' => get_security_group_ids,
      'fast_path_delete' => 'yes',
      'access_key_id' => @access_key_id,
      'secret_access_key' => @secret_access_key,
      'session_token' => @session_token,
      'max_retries' => 8,
      'encrypted' => true
    }
  end
  let(:my_cpi) do
    Bosh::AwsCloud::CloudV1.new(
      'aws' => aws_config,
      'registry' => {
        'endpoint' => 'fake',
        'user' => 'fake',
        'password' => 'fake'
      },
      'debug' => {
        'cpi' => {
          'api_version' => mock_cpi_api_version
        }
      }
    )
  end

  before do
    allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
    allow(registry).to receive(:read_settings).and_return({})
  end

  before do
    begin
      @ec2.instances(
        filters: [
          { name: 'tag-key', values: ['delete_me'] },
          { name: 'instance-state-name', values: %w[stopped stopping running pending] }
        ]
      ).each(&:terminate)
    rescue Aws::EC2::Errors::InvalidInstanceIdNotFound
      # don't blow up tests if instance that we're trying to delete was not found
    end

    @manual_subnet_cidr = @ec2.subnet(@manual_subnet_id).cidr_block
    manual_ips = IPAddr.new(@manual_subnet_cidr).to_range.to_a.map(&:to_s)
    ip_addresses = manual_ips.first(manual_ips.size - 1).drop(7)

    @ip_semaphore.synchronize do
      ip_addresses -= @already_used
      @manual_ip = ip_addresses[rand(ip_addresses.size)]
      @already_used << @manual_ip
    end
  end

  before { allow(Bosh::Clouds::Config).to receive_messages(logger: logger) }
  let(:logs) { STDOUT }
  let(:logger) { Bosh::Cpi::Logger.new(logs) }

  extend Bosh::Cpi::CompatibilityHelpers

  context 'manual networking' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @manual_ip, # use different IP to avoid race condition
          'cloud_properties' => { 'subnet' => @manual_subnet_id }
        }
      }
    end

    context 'with IPv6 address' do
      let(:instance_type) { instance_type_ipv6 }
      let(:network_spec) do
        {
          'ipv6' => {
            'type' => 'manual',
            'ip' => ipv6_ip,
            'cloud_properties' => { 'subnet' => @manual_subnet_id }
          }
        }
      end

      it 'is configured with the expected IPv6 address' do
        vm_lifecycle do |vm_id|
          resp = @cpi.ec2_resource.client.describe_instances(filters: [{ name: 'instance-id', values: [vm_id] }])
          expect(resp.reservations[0].instances[0].network_interfaces[0].ipv_6_addresses[0].ipv_6_address).to eq(ipv6_ip)
        end
      end
    end

    describe 'logging request_id' do
      let(:logs) { StringIO.new('') }
      let(:logger) { Bosh::Cpi::Logger.new(logs) }

      context 'when request_id is present in the context' do
        let(:endpoint_configured_cpi) do
          Bosh::AwsCloud::CloudV1.new(
            'aws' => {
              'region' => @region,
              'ec2_endpoint' => "https://ec2.#{@region}.amazonaws.com",
              'elb_endpoint' => "https://elasticloadbalancing.#{@region}.amazonaws.com",
              'default_key_name' => @default_key_name,
              'default_security_groups' => security_groups,
              'fast_path_delete' => 'yes',
              'access_key_id' => @access_key_id,
              'secret_access_key' => @secret_access_key,
              'session_token' => @session_token,
              'max_retries' => 8,
              'request_id' => '419877'
            },
            'registry' => {
              'endpoint' => 'fake',
              'user' => 'fake',
              'password' => 'fake'
            },
            'debug' => {
              'cpi' => {
                'api_version' => mock_cpi_api_version
              }
            }
          )
        end

        it 'logs request_id' do
          begin
            stemcell_id = endpoint_configured_cpi.create_stemcell('/not/a/real/path', 'ami' => { 'us-east-1' => ami })
            expect(logs.string).to include('req_id 419877')
          ensure
            endpoint_configured_cpi.delete_stemcell(stemcell_id) if stemcell_id
          end
        end
      end

      context 'when request_id is NOT present in the context' do
        let(:endpoint_configured_cpi) do
          Bosh::AwsCloud::CloudV1.new(
            'aws' => {
              'region' => @region,
              'ec2_endpoint' => "https://ec2.#{@region}.amazonaws.com",
              'elb_endpoint' => "https://elasticloadbalancing.#{@region}.amazonaws.com",
              'default_key_name' => @default_key_name,
              'default_security_groups' => security_groups,
              'fast_path_delete' => 'yes',
              'access_key_id' => @access_key_id,
              'secret_access_key' => @secret_access_key,
              'session_token' => @session_token,
              'max_retries' => 8
            },
            'registry' => {
              'endpoint' => 'fake',
              'user' => 'fake',
              'password' => 'fake'
            },
            'debug' => {
              'cpi' => {
                'api_version' => mock_cpi_api_version
              }
            }
          )
        end

        it 'does NOT log request_id' do
          begin
            stemcell_id = endpoint_configured_cpi.create_stemcell('/not/a/real/path', 'ami' => { 'us-east-1' => ami })
            expect(logs.string).to_not include('req_id: 419877')
          ensure
            endpoint_configured_cpi.delete_stemcell(stemcell_id) if stemcell_id
          end
        end
      end
    end

    context 'vm_type specifies elb for instance' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'elbs' => [@elb_id]
        }
      end
      let(:elb_client) do
        Aws::ElasticLoadBalancing::Client.new(
          access_key_id: @access_key_id,
          secret_access_key: @secret_access_key,
          session_token:  @session_token,
          region: @region
        )
      end

      it 'registers new instance with elb' do
        vm_lifecycle do |vm_id|
          instance_ids = elb_client.describe_load_balancers(load_balancer_names: [@elb_id]).load_balancer_descriptions
                                   .first.instances.map(&:instance_id)

          expect(instance_ids).to include(vm_id)
        end

        retry_options = { sleep: 10, tries: 10, on: RegisteredInstances }
        Bosh::Common.retryable(retry_options) do |tries, error|
          ensure_no_instances_registered_with_elb(elb_client, @elb_id)
        end

        instances = elb_client.describe_load_balancers(load_balancer_names: [@elb_id]).load_balancer_descriptions
                              .first.instances

        expect(instances).to be_empty
      end
    end

    context 'vm_type specifies lb_target_groups for instance' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'lb_target_groups' => [@target_group_name]
        }
      end
      let(:elb_v2_client) do
        Aws::ElasticLoadBalancingV2::Client.new(
          access_key_id: @access_key_id,
          secret_access_key: @secret_access_key,
          session_token:  @session_token,
          region: @region
        )
      end

      it 'registers new instance with target group' do
        vm_lifecycle do |instance_id|
          health_state = nil
          30.times do
            health = elb_v2_client.describe_target_health(
              target_group_arn: get_target_group_arn(@target_group_name),
              targets: [id: instance_id]
            ).target_health_descriptions

            health_description = health.first

            expect(health_description.target.id).to eq(instance_id)
            health_state = health_description.target_health.state
            break if health_state == 'unhealthy'

            sleep(15)
          end
          expect(health_state).to eq('unhealthy')
        end
      end
    end

    context 'without existing disks' do
      it 'should exercise the vm lifecycle' do
        vm_lifecycle do |instance_id|
          begin
            volume_id = @cpi.create_disk(2048, {}, instance_id)
            expect(volume_id).not_to be_nil
            expect(@cpi.has_disk?(volume_id)).to be(true)

            # ---- pre attach disk ----
            @cpi.attach_disk(instance_id, volume_id)

            snapshot_metadata = vm_metadata.merge(
              bosh_data: 'bosh data',
              instance_id: 'instance',
              agent_id: 'agent',
              director_name: 'Director',
              director_uuid: '6d06b0cc-2c08-43c5-95be-f1b2dd247e18'
            )
            snapshot_id = @cpi.snapshot_disk(volume_id, snapshot_metadata)
            expect(snapshot_id).not_to be_nil
            # ---- post attach disk, post snapshot_disk ----

            snapshot = @cpi.ec2_resource.snapshot(snapshot_id)
            expect(snapshot.description).to eq 'deployment/cpi_spec/0/sdf'
            # ---- post snapshot_disk, check snapshot ----

            snapshot_tags = array_key_value_to_hash(snapshot.tags)
            expect(snapshot_tags['device']).to eq '/dev/sdf'
            expect(snapshot_tags['agent_id']).to eq 'agent'
            expect(snapshot_tags['instance_id']).to eq 'instance'
            expect(snapshot_tags['director']).to eq 'Director'
            expect(snapshot_tags['director_name']).to be_nil
            expect(snapshot_tags['director_uuid']).to eq '6d06b0cc-2c08-43c5-95be-f1b2dd247e18'
            expect(snapshot_tags['Name']).to eq 'deployment/cpi_spec/0/sdf'
          ensure
            @cpi.delete_snapshot(snapshot_id) if snapshot_id
            Bosh::Common.retryable(tries: 25, on: Bosh::Clouds::DiskNotAttached, sleep: ->(n, _) { [2**(n - 1), 30].min }) do
              @cpi.detach_disk(instance_id, volume_id) if instance_id && volume_id
              true
            end
            @cpi.delete_disk(volume_id) if volume_id
          end
        end
      end
    end

    context 'with existing disks' do
      it 'can exercise the vm lifecycle and list the disks' do
        begin
          volume_id = nil
          vm_lifecycle do |instance_id|
            begin
              volume_id = @cpi.create_disk(2048, {}, instance_id)
              expect(volume_id).not_to be_nil
              expect(@cpi.has_disk?(volume_id)).to be(true)

              @cpi.attach_disk(instance_id, volume_id)
              expect(@cpi.get_disks(instance_id)).to include(volume_id)
            ensure
              Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: ->(n, _) { [2**(n - 1), 30].min }) do
                @cpi.detach_disk(instance_id, volume_id)
                true
              end
            end
          end
          vm_lifecycle(vm_disks: [volume_id]) do |instance_id|
            begin
              @cpi.attach_disk(instance_id, volume_id)
              expect(@cpi.get_disks(instance_id)).to include(volume_id)
            ensure
              Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: ->(n, _) { [2**(n - 1), 30].min }) do
                @cpi.detach_disk(instance_id, volume_id)
                true
              end
            end
          end
        ensure
          @cpi.delete_disk(volume_id) if volume_id
        end
      end
    end

    context 'when disk_pool.cloud_properties are empty' do
      let(:cloud_properties) { {} }

      it 'creates an unencrypted gp2 disk of the specified size' do
        begin
          volume_id = @cpi.create_disk(2048, cloud_properties)
          expect(volume_id).not_to be_nil
          expect(@cpi.has_disk?(volume_id)).to be(true)

          volume = @cpi.ec2_resource.volume(volume_id)
          expect(volume.encrypted).to be(false)
          expect(volume.volume_type).to eq('gp2')
          expect(volume.size).to eq(2)
        ensure
          @cpi.delete_disk(volume_id) if volume_id
        end
      end
    end

    context 'when disk_pool specifies a disk type' do
      let(:cloud_properties) { { 'type' => 'standard' } }

      it 'creates a disk of the given type' do
        begin
          volume_id = @cpi.create_disk(2048, cloud_properties)
          expect(volume_id).not_to be_nil
          expect(@cpi.has_disk?(volume_id)).to be(true)

          volume = @cpi.ec2_resource.volume(volume_id)
          expect(volume.volume_type).to eq('standard')
        ensure
          @cpi.delete_disk(volume_id) if volume_id
        end
      end
    end

    context 'when global config has encrypted true' do
      def check_encrypted_disk(cpi, cloud_properties, encrypted, kms_key_arn = nil)
        # NOTE: if provided KMS key does not exist, this method will throw Aws::EC2::Errors::InvalidVolumeNotFound
        # https://www.pivotaltracker.com/story/show/137931593
        volume_id = cpi.create_disk(2048, cloud_properties)
        expect(volume_id).not_to be_nil
        expect(cpi.has_disk?(volume_id)).to be(true)

        encrypted_volume = cpi.ec2_resource.volume(volume_id)
        expect(encrypted_volume.encrypted).to be(encrypted)
        unless kms_key_arn.nil?
          expect(encrypted_volume.kms_key_id).to eq(kms_key_arn)
        end
      ensure
        cpi.delete_disk(volume_id) if volume_id
      end

      let(:aws_config) do
        {
          'region' => @region,
          'default_key_name' => @default_key_name,
          'default_security_groups' => get_security_group_ids,
          'fast_path_delete' => 'yes',
          'access_key_id' => @access_key_id,
          'secret_access_key' => @secret_access_key,
          'session_token' => @session_token,
          'max_retries' => 8,
          'encrypted' => true
        }
      end

      context 'and encrypted flag is not provided in disk cloud properties' do
        let(:cloud_properties) { {} }

        it 'creates encrypted disk' do
          check_encrypted_disk(my_cpi, cloud_properties, true)
        end

        context 'and kms_key_arn is specified' do
          let(:cloud_properties) do
            {
              'kms_key_arn' => @kms_key_arn
            }
          end

          it 'creates an encrypted persistent disk' do
            check_encrypted_disk(my_cpi, cloud_properties, true, @kms_key_arn)
          end
        end
      end

      context 'and encrypted is overwritten to false in disk cloud properties' do
        let(:cloud_properties) { { 'encrypted' => false } }

        it 'creates unencrypted disk' do
          check_encrypted_disk(my_cpi, cloud_properties, false)
        end
      end

      context 'and global kms_key_arn are provided' do
        let(:aws_config) do
          {
            'region' => @region,
            'default_key_name' => @default_key_name,
            'default_security_groups' => get_security_group_ids,
            'fast_path_delete' => 'yes',
            'access_key_id' => @access_key_id,
            'secret_access_key' => @secret_access_key,
            'session_token' => @session_token,
            'max_retries' => 8,
            'encrypted' => true,
            'kms_key_arn' => @kms_key_arn
          }
        end

        context 'and disk cloud properties does NOT have kms_key_arn' do
          let(:cloud_properties) { {} }

          it 'creates disk with global kms_key_arn' do
            check_encrypted_disk(my_cpi, cloud_properties, true, @kms_key_arn)
          end
        end

        context 'and kms_key_arn is overwritten in stemcell properties' do
          let(:cloud_properties) { { 'kms_key_arn' => 'invalid-kms-key-arn-only-for-testing-overwrite' } }

          it 'should try to create disk with disk cloud properties kms_key_arn' do
            # It's faster to fail than providing another `kms_key_arn` and waiting for success
            # if the property wasn't being overwritten it would NOT fail
            # also no need to have another KMS key be provided in the tests
            expect do
              disk_id = my_cpi.create_disk(2048, cloud_properties)
              my_cpi.delete_disk(disk_id) if disk_id
            end.to raise_error(Aws::EC2::Errors::InvalidVolumeNotFound)
          end
        end
      end
    end

    it 'can create optimized magnetic disks' do
      begin
        minimum_magnetic_disk_size = 500 * 1024
        volume_id = @cpi.create_disk(minimum_magnetic_disk_size, 'type' => 'sc1')
        expect(volume_id).not_to be_nil
        expect(@cpi.has_disk?(volume_id)).to be(true)

        volume = @cpi.ec2_resource.volume(volume_id)
        expect(volume.volume_type).to eq('sc1')
      ensure
        @cpi.delete_disk(volume_id) if volume_id
      end
    end

    it 'can resize a disk' do
      begin
        volume_id = @cpi.create_disk(2048, {})
        @cpi.resize_disk(volume_id, 4096)
        expect(volume_id).not_to be_nil
        expect(@cpi.has_disk?(volume_id)).to be(true)

        volume = @cpi.ec2_resource.volume(volume_id)
        expect(volume.size).to eq(4)
      ensure
        @cpi.delete_disk(volume_id) if volume_id
      end
    end

    context 'when ephemeral_disk properties are specified' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'ephemeral_disk' => {
            'size' => 4 * 1024
          }
        }
      end
      let(:instance_type) { instance_type_without_ephemeral }

      it 'requests ephemeral disk with the specified size' do
        vm_lifecycle do |instance_id|
          instance_disks = @cpi.get_disks(instance_id)
          expect(instance_disks.size).to eq(2)

          ephemeral_volume = @cpi.ec2_resource.volume(instance_disks[1])
          expect(ephemeral_volume.size).to eq(4)
          expect(ephemeral_volume.volume_type).to eq('gp2')
          expect(ephemeral_volume.encrypted).to eq(false)
        end
      end

      context 'when iops are specified' do
        let(:vm_type) do
          {
            'instance_type' => instance_type,
            'availability_zone' => @subnet_zone,
            'ephemeral_disk' => {
              'size' => 4 * 1024,
              'type' => 'io1',
              'iops' => 100
            }
          }
        end

        it 'requests ephemeral disk with the specified iops' do
          vm_lifecycle do |instance_id|
            instance_disks = @cpi.get_disks(instance_id)
            expect(instance_disks.size).to eq(2)

            ephemeral_volume = @cpi.ec2_resource.volume(instance_disks[1])
            expect(ephemeral_volume.size).to eq(4)
            expect(ephemeral_volume.volume_type).to eq('io1')
            expect(ephemeral_volume.iops).to eq(100)

            expect(ephemeral_volume.encrypted).to eq(false)
          end
        end
      end

      context 'when ephemeral_disk.use_instance_storage is true' do
        let(:vm_type) do
          {
            'instance_type' => instance_type,
            'availability_zone' => @subnet_zone,
            'ephemeral_disk' => {
              'use_instance_storage' => true
            }
          }
        end
        let(:instance_type) { instance_type_with_ephemeral }

        it 'should not contain a block_device_mapping for /dev/sdb' do
          vm_lifecycle do |instance_id|
            block_device_mapping = @cpi.ec2_resource.instance(instance_id).block_device_mappings
            ebs_ephemeral = block_device_mapping.any? { |entry| entry.device_name == '/dev/sdb' }

            expect(ebs_ephemeral).to eq(false)
          end
        end
      end

      context 'when global config has encrypted true' do
        context 'and vm_type does NOT have encrypted' do
          let(:vm_type) do
            {
              'instance_type' => instance_type,
              'availability_zone' => @subnet_zone,
              'ephemeral_disk' => {
                'size' => 4 * 1024,
                'type' => 'io1',
                'iops' => 100
              }
            }
          end

          it 'creates an encrypted ephemeral disk' do
            vm_lifecycle(vm_disks: disks, ami_id: ami, cpi: my_cpi) do |instance_id|
              block_device_mapping = my_cpi.ec2_resource.instance(instance_id).block_device_mappings
              ephemeral_block_device = block_device_mapping.find { |entry| entry.device_name == '/dev/sdb' }

              ephemeral_disk = my_cpi.ec2_resource.volume(ephemeral_block_device.ebs.volume_id)

              expect(ephemeral_disk.encrypted).to be(true)
            end
          end

          context 'and the instance_type does not support encryption' do
            let(:instance_type) { 't1.micro' }
            let(:ami) { 'ami-3ec82656' }

            it 'raises an exception' do
              expect do
                vm_lifecycle(vm_disks: disks, ami_id: ami, cpi: my_cpi)
              end.to raise_error
            end
          end
        end

        context 'and encrypted is overwritten to false in vm_type' do
          let(:vm_type) do
            {
              'instance_type' => instance_type,
              'availability_zone' => @subnet_zone,
              'ephemeral_disk' => {
                'size' => 4 * 1024,
                'type' => 'io1',
                'iops' => 100,
                'encrypted' => false
              }
            }
          end

          it 'creates an unencrypted ephemeral disk' do
            vm_lifecycle(vm_disks: disks, ami_id: ami, cpi: my_cpi) do |instance_id|
              block_device_mapping = my_cpi.ec2_resource.instance(instance_id).block_device_mappings
              ephemeral_block_device = block_device_mapping.find { |entry| entry.device_name == '/dev/sdb' }

              ephemeral_disk = my_cpi.ec2_resource.volume(ephemeral_block_device.ebs.volume_id)

              expect(ephemeral_disk.encrypted).to be(false)
            end
          end
        end

        context 'and global kms_key_arn' do
          let(:aws_config) do
            {
              'region' => @region,
              'default_key_name' => @default_key_name,
              'default_security_groups' => get_security_group_ids,
              'fast_path_delete' => 'yes',
              'access_key_id' => @access_key_id,
              'secret_access_key' => @secret_access_key,
              'max_retries' => 8,
              'encrypted' => true,
              'kms_key_arn' => @kms_key_arn
            }
          end

          context 'and vm type cloud properties does NOT have kms_key_arn' do
            let(:vm_type) do
              {
                'instance_type' => instance_type,
                'availability_zone' => @subnet_zone,
                'ephemeral_disk' => {
                  'size' => 4 * 1024
                }
              }
            end

            it 'creates instance with ephemeral disk with global kms_key_arn' do
              vm_lifecycle(vm_disks: disks, ami_id: ami, cpi: my_cpi) do |instance_id|
                block_device_mapping = my_cpi.ec2_resource.instance(instance_id).block_device_mappings
                ephemeral_block_device = block_device_mapping.find { |entry| entry.device_name == '/dev/sdb' }

                ephemeral_disk = my_cpi.ec2_resource.volume(ephemeral_block_device.ebs.volume_id)

                expect(ephemeral_disk.encrypted).to be(true)
                expect(ephemeral_disk.kms_key_id).to eq(@kms_key_arn)
              end
            end
          end

          context 'and kms_key_arn is overwritten in vm type properties' do
            let(:vm_type) do
              {
                'instance_type' => instance_type,
                'availability_zone' => @subnet_zone,
                'ephemeral_disk' => {
                  'size' => 4 * 1024,
                  'encrypted' => true,
                  'kms_key_arn' => @kms_key_arn_override
                }
              }
            end

            it 'should try to create ephemeral disk vm type cloud properties kms_key_arn' do
              vm_lifecycle(vm_disks: disks, ami_id: ami, cpi: my_cpi) do |instance_id|
                block_device_mapping = my_cpi.ec2_resource.instance(instance_id).block_device_mappings
                ephemeral_block_device = block_device_mapping.find { |entry| entry.device_name == '/dev/sdb' }

                ephemeral_disk = my_cpi.ec2_resource.volume(ephemeral_block_device.ebs.volume_id)

                expect(ephemeral_disk.encrypted).to be(true)
                expect(ephemeral_disk.kms_key_id).to eq(@kms_key_arn_override)
              end
            end
          end
        end
      end
    end

    context 'when raw_instance_storage is true' do
      let(:vm_type) do
        {
          'instance_type' => instance_type,
          'availability_zone' => @subnet_zone,
          'raw_instance_storage' => true,
          'ephemeral_disk' => {
            'size' => 4 * 1024
          }
        }
      end
      let(:instance_type) { instance_type_with_ephemeral }

      it 'requests all available instance disks and puts the mappings in the registry' do
        vm_lifecycle do |instance_id|
          expect(@registry).to have_received(:update_settings).with(instance_id, hash_including(
            'disks' => {
              'system' => '/dev/xvda',
              'persistent' => {},
              'ephemeral' => '/dev/sdb',
              'raw_ephemeral' => [{'path' => '/dev/xvdba'}]
            }
          ))
        end
      end

      context 'when instance has NVMe SSD' do
        let(:instance_type) { instance_type_with_ephemeral_nvme }
        it 'uses the correct device file name for the raw ephemeral disk in the registry' do
          vm_lifecycle do |instance_id|
            expect(@registry).to have_received(:update_settings).with(instance_id, hash_including({
              'disks' => {
                'system' => '/dev/xvda',
                'persistent' => {},
                'ephemeral' => '/dev/sdb',
                'raw_ephemeral' => [{ 'path' => '/dev/nvme0n1' }]
              }
            }))
          end
        end
      end

      describe 'root device configuration' do
        let(:root_disk_size) { nil }
        let(:root_disk_type) { nil }

        context 'when root_disk properties are omitted' do
          context 'and AMI is hvm' do
            let(:root_disk_vm_props) do
              { ami_id: hvm_ami }
            end

            it 'requests root disk with the default type and size' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is paravirtual' do
            let(:root_disk_vm_props) do
              { ami_id: pv_ami }
            end

            it 'requests root disk with the default type and size' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is Windows' do
            let(:root_disk_vm_props) do
              { ami_id: windows_ami }
            end

            it 'requests root disk with the default type and size' do
              verify_root_disk_properties
            end
          end
        end

        context 'when root_disk properties are specified' do
          let(:root_disk_size) { 30 * 1024 }
          let(:vm_type) do
            {
              'instance_type' => instance_type,
              'availability_zone' => @subnet_zone,
              'root_disk' => {
                'size' => root_disk_size
              }
            }
          end

          context 'and AMI is hvm' do
            let(:root_disk_vm_props) do
              { ami_id: ami }
            end

            it 'requests root disk with the specified size and type gp2' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is pv' do
            let(:root_disk_vm_props) do
              { ami_id: pv_ami }
            end

            it 'requests root disk with the specified size and type gp2' do
              verify_root_disk_properties
            end
          end

          context 'and AMI is Windows' do
            let(:root_disk_vm_props) do
              { ami_id: windows_ami }
            end

            it 'requests root disk with the specified size and type gp2' do
              verify_root_disk_properties
            end
          end

          context 'and type is specified' do
            let(:root_disk_type) { 'standard' }
            let(:vm_type) do
              {
                'instance_type' => instance_type,
                'availability_zone' => @subnet_zone,
                'root_disk' => {
                  'size' => root_disk_size,
                  'type' => root_disk_type
                }
              }
            end

            context 'and AMI is hvm' do
              let(:root_disk_vm_props) do
                { ami_id: ami }
              end

              it 'requests root disk with the specified size and type gp2' do
                verify_root_disk_properties
              end
            end

            context 'and AMI is pv' do
              let(:root_disk_vm_props) do
                { ami_id: pv_ami }
              end

              it 'requests root disk with the specified size and type gp2' do
                verify_root_disk_properties
              end
            end

            context 'and AMI is Windows' do
              let(:root_disk_vm_props) do
                { ami_id: windows_ami }
              end

              it 'requests root disk with the specified size and type gp2' do
                verify_root_disk_properties
              end
            end
          end
        end

        def verify_root_disk_properties
          target_ami = @ec2.image(root_disk_vm_props[:ami_id])
          ami_root_device = get_root_block_device(target_ami.root_device_name, target_ami.block_device_mappings)

          ami_root_volume_size = ami_root_device.ebs.volume_size
          expect(ami_root_volume_size).to be > 0

          vm_lifecycle(root_disk_vm_props) do |instance_id|
            instance = @cpi.ec2_resource.instance(instance_id)
            instance_root_device = get_root_block_device(instance.root_device_name, instance.block_device_mappings)

            root_volume = @cpi.ec2_resource.volume(instance_root_device.ebs.volume_id)

            if root_disk_size
              expect(root_volume.size).to eq(root_disk_size / 1024)
            else
              expect(root_volume.size).to eq(ami_root_volume_size)
            end
            if root_disk_type
              expect(root_volume.volume_type).to eq(root_disk_type)
            else
              expect(root_volume.volume_type).to eq('gp2')
            end
          end
        end
      end
    end

    context 'when vm with attached disk is removed' do
      it 'should wait for 10 mins to attach disk/delete disk ignoring VolumeInUse error' do
        begin
          stemcell_id = @cpi.create_stemcell('/not/a/real/path', 'ami' => { @region => ami })
          vm_id = create_vm(
            nil,
            stemcell_id,
            vm_type,
            network_spec,
            [],
            nil
          )

          disk_id = @cpi.create_disk(2048, {}, vm_id)
          expect(@cpi.has_disk?(disk_id)).to be(true)

          @cpi.attach_disk(vm_id, disk_id)
          expect(@cpi.get_disks(vm_id)).to include(disk_id)

          @cpi.delete_vm(vm_id)
          vm_id = nil

          new_vm_id = create_vm(
            nil,
            stemcell_id,
            vm_type,
            network_spec,
            [disk_id],
            nil
          )

          expect do
            @cpi.attach_disk(new_vm_id, disk_id)
          end.to_not raise_error

          expect(@cpi.get_disks(new_vm_id)).to include(disk_id)
        ensure
          @cpi.delete_vm(new_vm_id) if new_vm_id
          @cpi.delete_disk(disk_id) if disk_id
          @cpi.delete_stemcell(stemcell_id) if stemcell_id
          @cpi.delete_vm(vm_id) if vm_id
        end
      end
    end

    it 'will not raise error when detaching a non-existing disk' do
      # Detaching a non-existing disk from vm should NOT raise error
      vm_lifecycle do |instance_id|
        expect do
          # long-gone volume id used, avoids `Aws::EC2::Errors::InvalidParameterValue`
          @cpi.detach_disk(instance_id, 'vol-092cfeeb61c2cf243')
        end.to_not raise_error
      end
    end

    context '#set_vm_metadata' do
      it 'correctly sets the tags set by #set_vm_metadata' do
        vm_lifecycle do |instance_id|
          instance = @cpi.ec2_resource.instance(instance_id)

          tags = array_key_value_to_hash(instance.tags)
          expect(tags['deployment']).to eq('deployment')
          expect(tags['job']).to eq('cpi_spec')
          expect(tags['index']).to eq('0')
          expect(tags['delete_me']).to eq('please')

          expect(instance.block_device_mappings.length).to eq(2) # root disk and ephemeral disk
          instance.block_device_mappings.each do |device|
            volume = @cpi.ec2_resource.volume(device.ebs.volume_id)
            volume_tags = array_key_value_to_hash(volume.tags)
            expect(volume_tags).to eq(tags)
          end
        end
      end
    end

    def create_vm(*args)
      vm_id = @cpi.create_vm(*args)
      vm_id = vm_id.first if @cpi_api_version >= 2
      vm_id
    end
  end
end
