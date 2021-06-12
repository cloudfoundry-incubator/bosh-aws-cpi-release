module Bosh::AwsCloud
  class VolumeManager
    def initialize(logger, aws_provider)
      @logger = logger
      @ec2_resource = aws_provider.ec2_resource
      @ec2_client = aws_provider.ec2_client
    end

    def create_ebs_volume(disk_config)
      volume_resp = @ec2_client.create_volume(disk_config)
      volume = Aws::EC2::Volume.new(id: volume_resp.volume_id, client: @ec2_client)

      @logger.info("Creating volume '#{volume.id}'")
      ResourceWait.for_volume(volume: volume, state: 'available')

      volume
    end

    def extend_ebs_volume(volume, new_size)
      resp = @ec2_client.modify_volume(volume_id: volume.id, size: new_size)

      volume_modification = SdkHelpers::VolumeModification.new(volume, resp.volume_modification, @ec2_client)
      @logger.info("Extending volume `#{volume.id}'")
      ResourceWait.for_volume_modification(volume_modification: volume_modification, state: 'completed')
    end

    def delete_ebs_volume(volume, fast_path_delete = false)
      @logger.info("Deleting volume `#{volume.id}'")

      # Retry 1, 6, 11, 15, 15, 15.. seconds. The total time is ~10 min.
      # VolumeInUse can be returned by AWS if disk was attached to VM
      # that was recently removed.
      tries = ResourceWait::DEFAULT_WAIT_ATTEMPTS
      sleep_cb = ResourceWait.sleep_callback(
        "Waiting for volume `#{volume.id}' to be deleted",
        {interval: 5, total: tries}
      )
      ensure_cb = Proc.new do |retries|
        cloud_error("Timed out waiting to delete volume `#{volume.id}'") if retries == tries
      end
      error = Aws::EC2::Errors::VolumeInUse

      Bosh::Common.retryable(tries: tries, sleep: sleep_cb, on: error, ensure: ensure_cb) do
        begin
          volume.delete
        rescue Aws::EC2::Errors::InvalidVolumeNotFound => e
          @logger.warn("Failed to delete disk '#{volume.id}' because it was not found: #{e.inspect}")
          raise Bosh::Clouds::DiskNotFound.new(false), "Disk '#{volume.id}' not found"
        end
        true # return true to only retry on Exceptions
      end

      if fast_path_delete
        begin
          TagManager.tag(volume, 'Name', 'to be deleted')
          @logger.info("Volume `#{volume.id}' has been marked for deletion")
        rescue Aws::EC2::Errors::InvalidVolumeNotFound
          # Once in a blue moon AWS if actually fast enough that the volume is already gone
          # when we get here, and if it is, our work here is done!
        end
        return
      end

      ResourceWait.for_volume(volume: volume, state: 'deleted')

      @logger.info("Volume `#{volume.id}' has been deleted")
    end

    def attach_ebs_volume(instance, volume)
      device_name = select_device_name(instance)
      cloud_error('Instance has too many disks attached') unless device_name

      # Work around AWS eventual (in)consistency:
      # even though we don't call attach_disk until the disk is ready,
      # AWS might still lie and say that the disk isn't ready yet, so
      # we try again just to be really sure it is telling the truth
      attachment_resp = nil

      @logger.debug("Attaching '#{volume.id}' to '#{instance.id}' as '#{device_name}'")

      # Retry every 1 sec for 15 sec, then every 15 sec for ~10 min
      # VolumeInUse can be returned by AWS if disk was attached to VM
      # that was recently removed.
      tries = ResourceWait::DEFAULT_WAIT_ATTEMPTS
      sleep_cb = ResourceWait.sleep_callback(
        "Attaching volume `#{volume.id}' to #{instance.id}",
        {interval: 0, tries_before_max: 15, total: tries}
      )

      Bosh::Common.retryable(
        on: [Aws::EC2::Errors::IncorrectState, Aws::EC2::Errors::VolumeInUse],
        sleep: sleep_cb,
        tries: tries
      ) do |retries, error|
        # Continue to retry after 15 attempts only for VolumeInUse
        if retries > 15 && error.instance_of?(Aws::EC2::Errors::IncorrectState)
          cloud_error("Failed to attach disk: #{error.message}")
        end

        attachment_resp = volume.attach_to_instance(instance_id: instance.id, device: device_name)
      end

      attachment = SdkHelpers::VolumeAttachment.new(attachment_resp, @ec2_resource)
      ResourceWait.for_attachment(attachment: attachment, state: 'attached')

      device_name = attachment.device
      @logger.info("Attached '#{volume.id}' to '#{instance.id}' as '#{device_name}'")

      device_name
    end

    def detach_ebs_volume(instance, volume, force = false)
      device_mapping = instance.block_device_mappings.select { |dm| dm.ebs.volume_id == volume.id }.first
      if device_mapping.nil?
        raise Bosh::Clouds::DiskNotAttached.new(true),
          "Disk `#{volume.id}' is not attached to instance `#{instance.id}'"
      end

      attachment_resp = volume.detach_from_instance(
        instance_id: instance.id,
        device: device_mapping.device_name,
        force: force
      )
      @logger.info("Detaching `#{volume.id}' from `#{instance.id}'")

      attachment = SdkHelpers::VolumeAttachment.new(attachment_resp, @ec2_resource)
      ResourceWait.for_attachment(attachment: attachment, state: 'detached')
    end

    private

    def select_device_name(instance)
      device_names = instance.block_device_mappings.map { |dm| dm.device_name }

      ('f'..'p').each do |char| # f..p is what console suggests
        device_name = "/dev/sd#{char}"
        return device_name unless device_names.include?(device_name)
        @logger.warn("'#{device_name}' on '#{instance.id}' is taken")
      end

      nil
    end
  end
end
