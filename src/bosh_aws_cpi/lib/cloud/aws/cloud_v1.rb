require 'cloud/aws/stemcell_finder'
require 'uri'

module Bosh::AwsCloud
  class CloudV1
    include Bosh::CloudV1
    include Helpers

    API_VERSION = 1
    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    attr_reader :ec2_resource
    attr_reader :registry
    attr_accessor :logger

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Hash] options CPI options
    # @option options [Hash] aws AWS specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      @config = Bosh::AwsCloud::Config.build(options.dup.freeze)
      @logger = Bosh::Clouds::Config.logger
      request_id = options['aws']['request_id']
      if request_id
        @logger.set_request_id(request_id)
      end

      if @config.registry_configured?
        @registry = Bosh::Cpi::RegistryClient.new(
          @config.registry.endpoint,
          @config.registry.user,
          @config.registry.password
        )
      else
        @registry = Bosh::AwsCloud::RegistryDisabledClient.new
      end

      @aws_provider = Bosh::AwsCloud::AwsProvider.new(@config.aws, @logger)
      @ec2_client = @aws_provider.ec2_client
      @ec2_resource = @aws_provider.ec2_resource
      @az_selector = AvailabilityZoneSelector.new(@ec2_resource)
      @volume_manager = Bosh::AwsCloud::VolumeManager.new(@logger, @aws_provider)

      @cloud_core = CloudCore.new(@config, @logger, @volume_manager, @az_selector, API_VERSION)

      @instance_manager = InstanceManager.new(@ec2_resource, @logger)
      @instance_type_mapper = InstanceTypeMapper.new

      @props_factory = Bosh::AwsCloud::PropsFactory.new(@config)
    end

    ##
    # Reads current instance id from EC2 metadata. We are assuming
    # instance id cannot change while current process is running
    # and thus memoizing it.
    def current_vm_id
      # xxxx = coreCloud.current_vm_id()
      # process xxxx based on version
      # return based on version

      return @current_vm_id if @current_vm_id

      http_client = HTTPClient.new
      http_client.connect_timeout = METADATA_TIMEOUT
      # Using 169.254.169.254 is an EC2 convention for getting
      # instance metadata
      uri = 'http://169.254.169.254/latest/meta-data/instance-id/'

      response = http_client.get(uri)
      unless response.status == 200
        cloud_error('Instance metadata endpoint returned ' \
                    "HTTP #{response.status}")
      end

      @current_vm_id = response.body
    rescue HTTPClient::TimeoutError
      cloud_error('Timed out reading instance metadata, ' \
                  'please make sure CPI is running on EC2 instance')
    end

    ##
    # Create an EC2 instance and wait until it's in running state
    # @param [String] agent_id agent id associated with new VM
    # @param [String] stemcell_id AMI id of the stemcell used to
    #  create the new instance
    # @param [Hash] vm_type resource pool specification
    # @param [Hash] network_spec network specification, if it contains
    #  security groups they must already exist
    # @param [optional, Array] disk_locality list of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment data to be merged into
    #   agent settings
    # @return [String] EC2 instance id of the new virtual machine
    def create_vm(agent_id, stemcell_id, vm_type, network_spec, disk_locality = [], environment = nil)
      raise Bosh::Clouds::CloudError, 'Cannot create VM without registry with CPI v1. Registry not configured.' unless @config.registry_configured?

      with_thread_name("create_vm(#{agent_id}, ...)") do
        network_props = @props_factory.network_props(network_spec)

        registry = { endpoint: @config.registry.endpoint }
        network_with_dns = network_props.dns_networks.first
        dns = { nameserver: network_with_dns.dns } unless network_with_dns.nil?
        registry_settings = AgentSettings.new(registry, network_props, dns)
        registry_settings.environment = environment
        registry_settings.agent_id = agent_id

        instance_id, = @cloud_core.create_vm(agent_id, stemcell_id, vm_type, network_props, registry_settings, disk_locality, environment) do |instance_id, settings|
          @registry.update_settings(instance_id, settings.agent_settings)
        end
        instance_id
      end
    end

    ##
    # Delete EC2 instance ("terminate" in AWS language) and wait until
    # it reports as terminated
    # @param [String] instance_id EC2 instance id
    def delete_vm(instance_id)
      with_thread_name("delete_vm(#{instance_id})") do
        logger.info("Deleting instance '#{instance_id}'")

        @cloud_core.delete_vm(instance_id) do |instance_id|
          @registry.delete_settings(instance_id)
        end
      end
    end

    ##
    # Reboot EC2 instance
    # @param [String] instance_id EC2 instance id
    def reboot_vm(instance_id)
      with_thread_name("reboot_vm(#{instance_id})") do
        @instance_manager.find(instance_id).reboot
      end
    end

    ##
    # Has EC2 instance
    # @param [String] instance_id EC2 instance id
    def has_vm?(instance_id)
      with_thread_name("has_vm?(#{instance_id})") do
        @instance_manager.find(instance_id).exists?
      end
    end

    # Add tags to an instance. In addition to the supplied tags,
    # it adds a 'Name' tag as it is shown in the AWS console.
    # @param [String] vm vm id that was once returned by {#create_vm}
    # @param [Hash] metadata metadata key/value pairs
    # @return [void]
    def set_vm_metadata(vm, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      instance = @ec2_resource.instance(vm)

      job = metadata['job']
      index = metadata['index']

      if metadata['name']
        metadata['Name'] = metadata.delete('name')
      elsif job && index
        metadata['Name'] = "#{job}/#{index}"
      elsif metadata['compiling']
        metadata['Name'] = "compiling/#{metadata['compiling']}"
      end

      begin
        TagManager.create_tags(instance, metadata)
      rescue Aws::EC2::Errors::TagLimitExceeded => e
        logger.error("could not tag #{instance.id}: #{e.message}")
      end

      get_volume_ids_for_vm(instance).each do |volume_id|
        begin
          TagManager.create_tags(@ec2_resource.volume(volume_id), metadata)
        rescue Aws::EC2::Errors::TagLimitExceeded => e
          logger.error("could not tag volume #{volume_id}: #{e.message}")
        end
      end
    rescue Aws::EC2::Errors::TagLimitExceeded => e
      logger.error("could not tag #{instance.id}: #{e.message}")
    end

    ##
    # Creates a new EBS volume
    # @param [Integer] size disk size in MiB
    # @param [optional, String] instance_id EC2 instance id
    #        of the VM that this disk will be attached to
    # @return [String] created EBS volume id
    def create_disk(size, cloud_properties, instance_id = nil)
      raise ArgumentError, 'disk size needs to be an integer' unless size.is_a?(Integer)

      with_thread_name("create_disk(#{size}, #{instance_id})") do
        props = @props_factory.disk_props(cloud_properties)

        volume_properties = VolumeProperties.new(
          size: size,
          type: props.type,
          iops: props.iops,
          az: @az_selector.select_availability_zone(instance_id),
          encrypted: props.encrypted,
          kms_key_arn: props.kms_key_arn
        )
        volume = @volume_manager.create_ebs_volume(volume_properties.persistent_disk_config)

        volume.id
      end
    end

    ##
    # Check whether an EBS volume exists or not
    #
    # @param [String] disk_id EBS volume UUID
    # @return [bool] whether the specific disk is there or not
    def has_disk?(disk_id)
      @cloud_core.has_disk?(disk_id)
    end

    ##
    # Delete EBS volume
    # @param [String] disk_id EBS volume id
    # @raise [Bosh::Clouds::CloudError] if disk is not in available state
    def delete_disk(disk_id)
      with_thread_name("delete_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)
        @volume_manager.delete_ebs_volume(volume, @config.aws.fast_path_delete?)
      end
    end

    def resize_disk(disk_id, new_size)
      with_thread_name("resize_disk(#{disk_id}, #{new_size})") do
        @cloud_core.resize_disk(disk_id, new_size)
      end
    end

    # Attach an EBS volume to an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to attach the disk to
    # @param [String] disk_id EBS volume id of the disk to attach
    def attach_disk(instance_id, disk_id)
      with_thread_name("attach_disk(#{instance_id}, #{disk_id})") do
        _ = @cloud_core.attach_disk(instance_id, disk_id) do |instance, device_name|
          update_agent_settings(instance_id) do |settings|
            settings['disks'] ||= {}
            settings['disks']['persistent'] ||= {}
            settings['disks']['persistent'][disk_id] = BlockDeviceManager.device_path(device_name, instance.instance_type, disk_id)
          end
        end
      end
    end

    # Detach an EBS volume from an EC2 instance
    # @param [String] instance_id EC2 instance id of the virtual machine to detach the disk from
    # @param [String] disk_id EBS volume id of the disk to detach
    def detach_disk(instance_id, disk_id)
      with_thread_name("detach_disk(#{instance_id}, #{disk_id})") do
        @cloud_core.detach_disk(instance_id, disk_id) do |disk_id|
          update_agent_settings(instance_id) do |settings|
            settings['disks'] ||= {}
            settings['disks']['persistent'] ||= {}
            settings['disks']['persistent'].delete(disk_id)
          end
        end
      end
    end

    def get_disks(vm_id)
      get_volume_ids_for_vm(@ec2_resource.instance(vm_id))
    end

    def set_disk_metadata(disk_id, metadata)
      with_thread_name("set_disk_metadata(#{disk_id}, ...)") do
        begin
          volume = @ec2_resource.volume(disk_id)
          TagManager.create_tags(volume, metadata)
        rescue Aws::EC2::Errors::TagLimitExceeded => e
          logger.error("could not tag #{volume.id}: #{e.message}")
        end
      end
    end

    # Take snapshot of disk
    # @param [String] disk_id disk id of the disk to take the snapshot of
    # @return [String] snapshot id
    def snapshot_disk(disk_id, metadata)
      metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]

      with_thread_name("snapshot_disk(#{disk_id})") do
        volume = @ec2_resource.volume(disk_id)
        devices = []
        volume.attachments.each { |attachment| devices << attachment.device }

        name = ['deployment', 'job', 'index'].collect { |key| metadata[key] }

        unless devices.empty?
          name << devices.first.split('/').last
          metadata['device'] = devices.first
        end

        snapshot = volume.create_snapshot(description: name.join('/'))
        logger.info("snapshot '#{snapshot.id}' of volume '#{disk_id}' created")

        metadata.merge!(
          'director' => metadata['director_name'],
          'instance_index' => metadata['index'].to_s,
          'instance_name' => metadata['job'] + '/' + metadata['instance_id'],
          'Name' => name.join('/')
        )

        %w[director_name index job].each do |tag|
          metadata.delete(tag)
        end

        TagManager.create_tags(snapshot, metadata)
        ResourceWait.for_snapshot(snapshot: snapshot, state: 'completed')
        snapshot.id
      end
    end

    # Delete a disk snapshot
    # @param [String] snapshot_id snapshot id to delete
    def delete_snapshot(snapshot_id)
      with_thread_name("delete_snapshot(#{snapshot_id})") do
        snapshot = @ec2_resource.snapshot(snapshot_id)
        begin
          snapshot.delete
        rescue Aws::EC2::Errors::InvalidSnapshotNotFound => e
          logger.info("snapshot '#{snapshot_id}' not found")
        end
        logger.info("snapshot '#{snapshot_id}' deleted")
      end
    end

    # Configure network for an EC2 instance. No longer supported.
    # @param [String] instance_id EC2 instance id
    # @param [Hash] network_spec network properties
    # @raise [Bosh::Clouds:NotSupported] configure_networks is no longer supported
    def configure_networks(instance_id, network_spec)
      raise Bosh::Clouds::NotSupported, 'configure_networks is no longer supported'
    end

    ##
    # Creates a new EC2 AMI using stemcell image.
    # This method can only be run on an EC2 instance, as image creation
    # involves creating and mounting new EBS volume as local block device.
    # @param [String] image_path local filesystem path to a stemcell image
    # @param [Hash] cloud_properties AWS-specific stemcell properties
    # @option cloud_properties [String] kernel_id
    #   AKI, auto-selected based on the architecture and root device, unless specified
    # @option cloud_properties [String] root_device_name
    #   block device path (e.g. /dev/sda1), provided by the stemcell manifest, unless specified
    # @option cloud_properties [String] architecture
    #   instruction set architecture (e.g. x86_64), provided by the stemcell manifest,
    #   unless specified
    # @option cloud_properties [String] disk (2048)
    #   root disk size
    # @return [String] EC2 AMI name of the stemcell
    def create_stemcell(image_path, stemcell_properties)
      with_thread_name("create_stemcell(#{image_path}...)") do
        props = @props_factory.stemcell_props(stemcell_properties)

        if props.is_light?
          # select the correct image for the configured ec2 client
          available_image = @ec2_resource.images(
            filters: [{
              name: 'image-id',
              values: props.ami_ids
            }]
          ).first
          raise Bosh::Clouds::CloudError, "Stemcell does not contain an AMI in region #{@config.aws.region}" unless available_image

          if props.encrypted
            copy_image_result = @ec2_client.copy_image(
              source_region: @config.aws.region,
              source_image_id: props.region_ami,
              name: "Copied from SourceAMI #{props.region_ami}",
              encrypted: props.encrypted,
              kms_key_id: props.kms_key_arn
            )

            encrypted_image_id = copy_image_result.image_id
            encrypted_image = @ec2_resource.image(encrypted_image_id)
            ResourceWait.for_image(image: encrypted_image, state: 'available')

            return encrypted_image_id.to_s
          end

          "#{available_image.id} light"
        else
          create_ami_for_stemcell(image_path, props)
        end
      end
    end

    # Delete a stemcell and the accompanying snapshots
    # @param [String] stemcell_id EC2 AMI name of the stemcell to be deleted
    def delete_stemcell(stemcell_id)
      with_thread_name("delete_stemcell(#{stemcell_id})") do
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)
        stemcell.delete
      end
    end
    # Map a set of cloud agnostic VM properties (cpu, ram, ephemeral_disk_size) to
    # a set of AWS specific cloud_properties
    # @param [Hash] vm_properties requested cpu, ram, and ephemeral_disk_size
    # @return [Hash] AWS specific cloud_properties describing instance (e.g. instance_type)
    def calculate_vm_cloud_properties(vm_properties)
      required_keys = ['cpu', 'ram', 'ephemeral_disk_size']
      missing_keys = required_keys.reject { |key| vm_properties[key] }
      unless missing_keys.empty?
        missing_keys.map! { |k| "'#{k}'" }
        raise "Missing VM cloud properties: #{missing_keys.join(', ')}"
      end

      instance_type = @instance_type_mapper.map(vm_properties)
      {
        'instance_type' => instance_type,
        'ephemeral_disk' => {
          'size' => vm_properties['ephemeral_disk_size']
        }
      }
    end

    # Information about AWS CPI, currently supported stemcell formats
    # @return [Hash] AWS CPI properties
    def info
      @cloud_core = CloudCore.new(@config, @logger, @volume_manager, @az_selector, API_VERSION)
      @cloud_core.info
    end

    private

    def update_agent_settings(instance_id)
      raise ArgumentError, 'block is not provided' unless block_given?

      settings = registry.read_settings(instance_id)
      yield settings
      registry.update_settings(instance_id, settings)
      logger.debug("updated registry settings: #{registry.read_settings(instance_id)}")
    end

    def create_ami_for_stemcell(image_path, stemcell_cloud_props)
      creator = StemcellCreator.new(@ec2_resource, stemcell_cloud_props)

      begin
        director_vm_id = current_vm_id
        instance = nil
        volume = nil

        instance = @ec2_resource.instance(director_vm_id)
        unless instance.exists?
          cloud_error(
            "Could not locate the current VM with id '#{director_vm_id}'." \
                'Ensure that the current VM is located in the same region as configured in the manifest.'
          )
        end

        disk_config = VolumeProperties.new(
          size: stemcell_cloud_props.disk,
          az: @az_selector.select_availability_zone(director_vm_id),
          encrypted: stemcell_cloud_props.encrypted,
          kms_key_arn: stemcell_cloud_props.kms_key_arn
        ).persistent_disk_config
        volume = @volume_manager.create_ebs_volume(disk_config)
        requested_path = @volume_manager.attach_ebs_volume(instance, volume)

        logger.debug("Requested block device: #{requested_path}")
        expected_path = BlockDeviceManager.device_path(
          requested_path,
          instance.instance_type,
          volume.id
        )

        logger.debug("Expected block device: #{expected_path}")
        actual_path = BlockDeviceManager.block_device_ready?(expected_path)

        logger.debug("Actual block device: #{actual_path}")
        logger.info("Creating stemcell with: '#{volume.id}'")
        creator.create(volume, actual_path, image_path).id
      rescue => e
        logger.error(e)
        raise e
      ensure
        if instance && volume
          @volume_manager.detach_ebs_volume(instance.reload, volume, true)
          @volume_manager.delete_ebs_volume(volume)
        end
      end
    end

    def get_volume_ids_for_vm(vm_instance)
      vm_instance.block_device_mappings.select(&:ebs)
                 .map { |block_device| block_device.ebs.volume_id }
    end
  end
end
