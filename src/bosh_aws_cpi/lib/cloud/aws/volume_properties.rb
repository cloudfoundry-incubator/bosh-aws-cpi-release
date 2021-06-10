module Bosh
  module AwsCloud
    class VolumeProperties
      include Helpers

      attr_reader :size, :az, :iops, :type, :encrypted

      def initialize(options)
        @size = options[:size] || 0
        @type = options[:type] || 'gp2'
        @iops = options[:iops]
        @throughput = options[:throughput]
        @az = options[:az]
        @kms_key_arn = options[:kms_key_arn]
        @encrypted = options[:encrypted] || false
        @root_device_name = options[:root_device_name] || '/dev/xvda'
        @tags = options[:tags] || []
      end

      def ephemeral_disk_config()
        mapping = {
          volume_size: size_in_gb,
          volume_type: @type,
          delete_on_termination: true
        }

        mapping[:iops] = @iops if @iops
        mapping[:encrypted] = @encrypted if @encrypted
        mapping[:kms_key_id] = @kms_key_arn if @kms_key_arn

        { device_name: '/dev/sdb', ebs: mapping }
      end

      def persistent_disk_config
        output = {
          size: size_in_gb,
          availability_zone: @az,
          volume_type: @type,
          encrypted: @encrypted
        }

        output[:iops] = @iops if @iops
        output[:throughput] = @throughput if @throughput
        output[:kms_key_id] = @kms_key_arn if @kms_key_arn
        unless @tags.empty?
          output[:tag_specifications] = [
            { resource_type: 'volume', tags: @tags }
          ]
        end
        output
      end

      def root_disk_config
        root_device = {
          :volume_type => @type,
          :delete_on_termination => true
        }
        if @size > 0
          root_device[:volume_size] = size_in_gb
        end

        if @type == 'io1' && @iops > 0
          root_device[:iops] = @iops
        end

        {
          device_name: @root_device_name,
          ebs: root_device
        }
      end

      private

      def size_in_gb
        (@size / 1024.0).ceil
      end
    end
  end
end
