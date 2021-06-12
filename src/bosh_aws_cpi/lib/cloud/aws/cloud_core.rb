require 'cloud/aws/stemcell_finder'
require 'uri'

module Bosh::AwsCloud
  class CloudCore
    include Helpers

    METADATA_TIMEOUT = 5 # in seconds
    DEVICE_POLL_TIMEOUT = 60 # in seconds

    attr_reader :ec2_resource
    attr_reader :logger

    ##
    # Initialize BOSH AWS CPI. The contents of sub-hashes are defined in the {file:README.md}
    # @param [Bosh::AwsCloud::Config] config CPI Config options
    # @param [Bosh::Cpi::Logger] logger AWS specific options
    # @param [Bosh::AwsCloud::VolumeManager] volume manager
    # @param [Bosh::AwsCloud::AvailabilityZoneSelector] az selector
    # @param [Integer] Stemcell api version
    def initialize(config, logger, volume_manager, az_selector, stemcell_api_version)
      @config = config
      @supported_api_version = @config.supported_api_version
      @stemcell_api_version = stemcell_api_version
      @logger = logger

      @aws_provider = Bosh::AwsCloud::AwsProvider.new(@config.aws, @logger)
      @ec2_client = @aws_provider.ec2_client
      @ec2_resource = @aws_provider.ec2_resource

      @az_selector = az_selector
      @volume_manager = volume_manager

      @instance_manager = InstanceManager.new(@ec2_resource, @logger)
      @instance_type_mapper = InstanceTypeMapper.new

      @props_factory = Bosh::AwsCloud::PropsFactory.new(@config)
    end

    # Information about AWS CPI, currently supported stemcell formats
    # @return [Hash] AWS CPI properties
    def info
      {
        'stemcell_formats' => %w(aws-raw aws-light),
        'api_version' => @supported_api_version
      }
    end

    ##
    # Create an EC2 instance and wait until it's in running state
    # @param [String] agent_id agent id associated with new VM
    # @param [String] stemcell_id AMI id of the stemcell used to
    #  create the new instance
    # @param [Hash] vm_type resource pool specification
    # @param [Bosh::AwsCloud::NetworkCloudProps] network_props network specification, if it contains
    #  security groups they must already exist
    # @param [optional, Array] disk_locality list of disks that
    #   might be attached to this instance in the future, can be
    #   used as a placement hint (i.e. instance will only be created
    #   if resource pool availability zone is the same as disk
    #   availability zone)
    # @param [optional, Hash] environment data to be merged into
    #   agent settings
    # @return String, Hash - EC2 instance id of the new virtual machine, Network info
    def create_vm(agent_id, stemcell_id, vm_type, network_props, settings, disk_locality = [], environment = nil)
      vm_props = @props_factory.vm_props(vm_type)

      target_groups = vm_props.lb_target_groups
      requested_elbs = vm_props.elbs

      begin
        stemcell = StemcellFinder.find_by_id(@ec2_resource, stemcell_id)

        block_device_mappings, agent_disk_info = Bosh::AwsCloud::BlockDeviceManager.new(
          @logger,
          stemcell,
          vm_props,
        ).mappings_and_info

        settings.agent_disk_info = agent_disk_info
        settings.root_device_name = stemcell.root_device_name
        settings.agent_config = @config.agent

        tags = {}
        if environment && environment['bosh'] && environment['bosh']['tags']
          tags = environment['bosh']['tags']
        end

        instance = @instance_manager.create(
          stemcell.image_id,
          vm_props,
          network_props,
          (disk_locality || []),
          @config.aws.default_security_groups,
          block_device_mappings,
          settings.encode(@stemcell_api_version),
          tags
        )

        target_groups.each do |target_group_name|
          target_group = LBTargetGroup.new(client: @aws_provider.alb_client, group_name: target_group_name)
          target_group.register(instance.id)
          @logger.info("Registered #{instance.id} with #{target_group_name}")
        end

        requested_elbs.each do |requested_elb_name|
          requested_elb = ClassicLB.new(client: @aws_provider.elb_client, elb_name: requested_elb_name)
          requested_elb.register(instance.id)
        end

        logger.info("Creating new instance '#{instance.id}'")

        NetworkConfigurator.new(network_props).configure(@ec2_resource, instance)

        yield(instance.id, settings) if block_given?

        #TODO: we should get network props from instance.network_interfaces
        return instance.id, network_props
      rescue => e # is this rescuing too much?
        logger.error(%Q[Failed to create instance: #{e.message}\n#{e.backtrace.join("\n")}])
        instance.terminate(@config.aws.fast_path_delete?) if instance
        raise e
      end
    end

    # Attaches a disk
    # @param [String] instance_id vm id that was once returned by {#create_vm}
    # @param [String] disk_id disk id that was once returned by {#create_disk}
    # @return [String] hint for location of attached disk
    def attach_disk(instance_id, disk_id)
      instance = @ec2_resource.instance(instance_id)
      volume = @ec2_resource.volume(disk_id)

      device_name = @volume_manager.attach_ebs_volume(instance, volume)
      logger.info("Attached `#{disk_id}' to `#{instance_id}'")

      yield(instance, device_name) if block_given?

      return device_name
    end

    def delete_vm(instance_id)
      @instance_manager.find(instance_id).terminate(@config.aws.fast_path_delete?)

      yield instance_id if block_given?
    end

    def detach_disk(instance_id, disk_id)
      instance = @ec2_resource.instance(instance_id)
      volume = @ec2_resource.volume(disk_id)

      if has_disk?(disk_id)
        @volume_manager.detach_ebs_volume(instance, volume)
      else
        @logger.info("Disk `#{disk_id}' not found while trying to detach it from vm `#{instance_id}'...")
      end

      yield(disk_id) if block_given?

      logger.info("Detached `#{disk_id}' from `#{instance_id}'")
    end


    def resize_disk(disk_id, new_size)
      new_size_gib = mib_to_gib(new_size)
      @logger.info("Resizing volume `#{disk_id}'...")
      volume = @ec2_resource.volume(disk_id)
      cloud_error("Cannot resize volume because volume with #{disk_id} not found") unless volume
      actual_size_gib = volume.size
      if actual_size_gib == new_size_gib
        @logger.info("Skipping resize of disk #{disk_id} because current value #{actual_size_gib} GiB" \
                     " is equal new value #{new_size_gib} GiB")
      elsif actual_size_gib > new_size_gib
        cloud_error("Cannot resize volume to a smaller size from #{actual_size_gib} GiB to #{new_size_gib} GiB")
      else
        attachments = volume.attachments
        unless attachments.empty?
          cloud_error("Cannot resize volume '#{disk_id}' it still has #{attachments.size} attachment(s)")
        end
        @volume_manager.extend_ebs_volume(volume, new_size_gib)
        @logger.info("Disk #{disk_id} resized from #{actual_size_gib} GiB to #{new_size_gib} GiB")
      end
    end


    def has_disk?(disk_id)
      with_thread_name("has_disk?(#{disk_id})") do
        @logger.info("Check the presence of disk with id `#{disk_id}'...")
        volume = @ec2_resource.volume(disk_id)
        begin
          volume.state
        rescue Aws::EC2::Errors::InvalidVolumeNotFound
          return false
        end
        true
      end
    end

    def mib_to_gib(size)
      (size / 1024.0).ceil
    end
  end
end
