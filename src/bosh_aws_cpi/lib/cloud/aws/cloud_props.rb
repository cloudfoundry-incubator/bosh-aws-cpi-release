include Bosh::AwsCloud::Helpers

module Bosh::AwsCloud
  class StemcellCloudProps
    attr_reader :ami
    attr_reader :disk, :architecture, :virtualization_type, :root_device_name, :kernel_id
    # AWS Permissions: ec2:CopyImage
    attr_reader :encrypted, :kms_key_arn

    # @param [Hash] cloud_properties
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(cloud_properties, global_config)
      @global_config = global_config
      @cloud_properties = cloud_properties.merge(@global_config.aws.stemcell)

      @ami = @cloud_properties['ami']

      @encrypted = @global_config.aws.encrypted
      @encrypted = !!@cloud_properties['encrypted'] if @cloud_properties.key?('encrypted')

      @kms_key_arn = @global_config.aws.kms_key_arn
      @kms_key_arn = @cloud_properties['kms_key_arn'] if @cloud_properties.key?('kms_key_arn')

      @name = @cloud_properties['name']
      @version = @cloud_properties['version']

      @disk = @cloud_properties['disk'] || DEFAULT_DISK_SIZE
      @architecture = @cloud_properties['architecture']
      @virtualization_type = @cloud_properties['virtualization_type'] || 'hvm'
      @root_device_name = @cloud_properties['root_device_name']
      @kernel_id = @cloud_properties['kernel_id']
    end

    # old stemcells doesn't have name & version
    def old?
      @name && @version
    end

    def formatted_name
      "#{@name} #{@version}"
    end

    def paravirtual?
      virtualization_type == PARAVIRTUAL
    end

    def is_light?
      !ami.nil? && !ami.empty?
    end

    def ami_ids
      ami.values
    end

    def region_ami
      ami[@global_config.aws.region]
    end

    private

    DEFAULT_DISK_SIZE = 2048
    PARAVIRTUAL = 'paravirtual'.freeze
  end

  class DiskCloudProps
    attr_reader :type, :iops, :throughput, :encrypted, :kms_key_arn

    # @param [Hash] cloud_properties
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(cloud_properties, global_config)
      @type = cloud_properties['type']
      @iops = cloud_properties['iops']
      @throughput = cloud_properties['throughput']

      @encrypted = global_config.aws.encrypted
      @encrypted = !!cloud_properties['encrypted'] if cloud_properties.key?('encrypted')

      @kms_key_arn = global_config.aws.kms_key_arn
      @kms_key_arn = cloud_properties['kms_key_arn'] if cloud_properties.key?('kms_key_arn')
    end
  end

  class VMCloudProps
    attr_reader :instance_type, :availability_zone, :security_groups, :key_name
    attr_reader :spot_bid_price, :spot_ondemand_fallback
    attr_reader :placement_group, :tenancy, :auto_assign_public_ip
    attr_reader :raw_instance_storage
    attr_reader :ephemeral_disk, :root_disk
    # AWS Permissions: iam:PassRole
    attr_reader :iam_instance_profile
    # AWS Permissions: elasticloadbalancing:{DescribeLoadBalancers, RegisterInstancesWithLoadBalancer}
    attr_reader :elbs
    # AWS Permissions: elasticloadbalancing:{DescribeTargetHealth, RegisterTargets, DescribeTargetGroups,DescribeLoadBalancers}
    attr_reader :lb_target_groups
    # AWS Permissions: ec2:{CreateRoute, ReplaceRoute, DescribeRouteTables}
    attr_reader :advertised_routes
    # AWS Permissions: ec2:ModifyInstanceAttribute
    attr_reader :source_dest_check

    # @param [Hash] cloud_properties
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(cloud_properties, global_config)
      @cloud_properties = cloud_properties.dup

      @instance_type = cloud_properties['instance_type']
      @availability_zone = cloud_properties['availability_zone']
      @security_groups = cloud_properties['security_groups'] || []
      @key_name = cloud_properties['key_name'] || global_config.aws.default_key_name
      @spot_bid_price = cloud_properties['spot_bid_price']
      @spot_ondemand_fallback = !!cloud_properties['spot_ondemand_fallback']
      @elbs = cloud_properties['elbs'] || []
      @lb_target_groups = cloud_properties['lb_target_groups'] || []
      @iam_instance_profile = cloud_properties['iam_instance_profile'] || global_config.aws.default_iam_instance_profile
      @placement_group = cloud_properties['placement_group']
      @tenancy = Tenancy.new(cloud_properties['tenancy'])
      @auto_assign_public_ip = cloud_properties['auto_assign_public_ip']
      @advertised_routes = (cloud_properties['advertised_routes'] || []).map do |route|
        AdvertisedRoute.new(route)
      end
      @raw_instance_storage = !!cloud_properties['raw_instance_storage']
      @source_dest_check = true
      @source_dest_check = !!cloud_properties['source_dest_check'] unless cloud_properties['source_dest_check'].nil?

      @ephemeral_disk = EphemeralDisk.new(@cloud_properties['ephemeral_disk'], global_config)
      @cloud_properties['ephemeral_disk'] = @ephemeral_disk.disk if !@ephemeral_disk.disk.nil?

      @root_disk = RootDisk.new(@cloud_properties['root_disk'])
      @cloud_properties['root_disk'] = @root_disk.disk if !@root_disk.disk.nil?
    end

    def raw_instance_storage?
      @raw_instance_storage
    end

    class Tenancy
      def initialize(tenancy)
        @tenancy = tenancy || 'default'
      end

      def dedicated?
        @tenancy == 'dedicated'
      end

      def dedicated
        'dedicated'
      end
    end

    class AdvertisedRoute
      attr_reader :table_id, :destination

      def initialize(advertised_route)
        @table_id = advertised_route['table_id']
        @destination = advertised_route['destination']
      end
    end

    class Disk
      attr_reader :size, :type, :iops, :disk

      def initialize(disk)
        if disk
          @disk = disk.dup

          @size = disk['size']
          @type = disk['type']
          @iops = disk['iops']
        end
      end

      def specified?
        disk && disk.key?('size')
      end
    end

    class EphemeralDisk < Disk
      attr_reader :use_instance_storage, :encrypted, :kms_key_arn, :use_root_disk

      def initialize(ephemeral_disk, global_config)
        super(ephemeral_disk)

        @encrypted = global_config.aws.encrypted
        @kms_key_arn = global_config.aws.kms_key_arn

        if ephemeral_disk
          @use_instance_storage = !!ephemeral_disk['use_instance_storage'] || false

          @use_root_disk = !!ephemeral_disk['use_root_disk'] if ephemeral_disk.key?('use_root_disk')

          @encrypted = !!ephemeral_disk['encrypted'] if ephemeral_disk.key?('encrypted')
          @kms_key_arn = ephemeral_disk['kms_key_arn'] if ephemeral_disk.key?('kms_key_arn')
        end
      end

      def invalid_instance_storage_config?
        if use_instance_storage
          size || type || iops || encrypted
        end
      end
    end

    class RootDisk < Disk
    end
  end

  class NetworkCloudProps
    attr_reader :networks

    # @param [Hash] network_spec
    # @param [Bosh::AwsCloud::Config] global_config
    def initialize(network_spec, global_config)
      @network_spec = (network_spec || {}).dup

      @networks = []
      @networks = @network_spec.map do |network_name, settings|
        Network.create(network_name, settings)
      end
    end

    def security_groups
      @networks.map do |network|
        network.security_groups
      end.flatten.sort.uniq
    end

    def filter(*types)
      # raise "error" if ![Network::MANUAL, Network::DYNAMIC, Network::PUBLIC].include?(types)
      networks.select do |net|
        types.include?(net.type)
      end
    end

    def dns_networks
      filter(Network::MANUAL).reject do |net|
        net.dns.nil?
      end
    end

    def ipv6_networks
      filter(Network::MANUAL).select do |net|
        net.ip.to_s.include?(':')
      end
    end

    class Network
      attr_reader :name, :type, :subnet, :security_groups

      MANUAL = 'manual'.freeze
      DYNAMIC = 'dynamic'.freeze
      PUBLIC = 'vip'.freeze

      def initialize(name, settings)
        @settings = settings.dup

        @name = name
        @type = settings['type'] || MANUAL
        @cloud_properties = settings['cloud_properties']

        @security_groups = []

        if cloud_properties?
          @subnet = settings['cloud_properties']['subnet']
          @security_groups = settings['cloud_properties']['security_groups'] || []
        end
      end

      def cloud_properties?
        !@cloud_properties.nil?
      end

      def to_h
        @settings
      end

      def self.create(name, settings)
        case settings['type']
          when DYNAMIC
            DynamicNetwork.new(name, settings)
          when PUBLIC
            PublicNetwork.new(name, settings)
          when MANUAL, nil
            ManualNetwork.new(name, settings)
          else
            cloud_error("Invalid network type '#{settings['type']}' for AWS, " \
                        "can only handle 'dynamic', 'vip', or 'manual' network types")
        end
      end
    end

    class ManualNetwork < Network
      attr_reader :netmask, :gateway, :default, :dns, :ip

      def initialize(name, settings)
        super(name, settings)

        @netmask = settings['netmask']
        @gateway = settings['gateway']
        @default = settings['default']
        @ip = settings['ip']
        @dns = settings['dns']

        # TODO (cdutra): not used by aws cpi but used by other cpis
        # @gateway = settings['gateway']
        # @mac = settings['mac']
      end
    end

    class DynamicNetwork < Network
      def initialize(name, settings)
        super(name, settings)
      end
    end

    class PublicNetwork < Network
      attr_reader :ip

      def initialize(name, settings)
        super(name, settings)

        @ip = settings['ip']
      end
    end
  end

  class PropsFactory
    def initialize(config)
      @config = config
    end

    def stemcell_props(stemcell_properties)
      Bosh::AwsCloud::StemcellCloudProps.new(stemcell_properties, @config)
    end

    def disk_props(disk_properties)
      Bosh::AwsCloud::DiskCloudProps.new(disk_properties, @config)
    end

    def vm_props(vm_properties)
      Bosh::AwsCloud::VMCloudProps.new(vm_properties, @config)
    end

    def network_props(network_spec)
      Bosh::AwsCloud::NetworkCloudProps.new(network_spec, @config)
    end
  end
end
