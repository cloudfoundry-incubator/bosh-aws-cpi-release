module Bosh::AwsCloud::SdkHelpers

   class VolumeModification

    attr_reader :volume
    attr_reader :resource_client
    attr_reader :modification

    def initialize(volume, modification, resource_client)
      @volume = volume
      @resource_client = resource_client
      @modification = modification
    end

    def state
      @modification.modification_state
    end

    def data
      @volume.data
    end

    def reload
      resp = @resource_client.describe_volumes_modifications(volume_ids: [ @volume.id])
      if resp.volumes_modifications.empty?
        raise Aws::EC2::Errors::InvalidVolumeNotFound.new(nil, "Unable to find disk modification for volume '#{@volume.id}'")
      end
      @modification = resp.volumes_modifications[0]
    end
  end

end
