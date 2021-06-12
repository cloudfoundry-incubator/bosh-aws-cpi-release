module Bosh
  module AwsCloud; end
end

require 'aws-sdk-core'
require 'aws-sdk-ec2'
require 'aws-sdk-elasticloadbalancing'
require 'aws-sdk-elasticloadbalancingv2'

require 'httpclient'
require 'pp'
require 'set'
require 'tmpdir'
require 'securerandom'
require 'json'

require 'common/exec'
require 'common/thread_pool'
require 'common/thread_formatter'

require 'bosh/cpi/registry_client'

require 'cloud'
require 'cloud/aws/helpers'
require 'cloud/aws/cloud_core'
require 'cloud/aws/cloud_v1'
require 'cloud/aws/cloud_v2'
require 'cloud/aws/registry_disabled_client'
require 'cloud/aws/config'
require 'cloud/aws/aws_provider'
require 'cloud/aws/cloud_props'

require 'cloud/aws/agent_settings'

require 'cloud/aws/aki_picker'
require 'cloud/aws/network_configurator'
require 'cloud/aws/stemcell'
require 'cloud/aws/stemcell_creator'
require 'cloud/aws/instance_manager'
require 'cloud/aws/instance'
require 'cloud/aws/spot_manager'
require 'cloud/aws/tag_manager'
require 'cloud/aws/availability_zone_selector'
require 'cloud/aws/resource_wait'
require 'cloud/aws/volume_properties'
require 'cloud/aws/instance_param_mapper'
require 'cloud/aws/security_group_mapper'
require 'cloud/aws/block_device_manager'
require 'cloud/aws/instance_type_mapper'
require 'cloud/aws/classic_lb'
require 'cloud/aws/lb_target_group'
require 'cloud/aws/sdk_helpers/volume_attachment'
require 'cloud/aws/sdk_helpers/volume_modification'
require 'cloud/aws/sdk_helpers/volume_manager'

module Bosh
  module Clouds
    class Aws
      def create_cloud(cpi_api_version, cloud_properties)
        if cpi_api_version && cpi_api_version > 1
          Bosh::AwsCloud::CloudV2.new(cloud_properties)
        else
          Bosh::AwsCloud::CloudV1.new(cloud_properties)
        end
      end
    end
  end
end
