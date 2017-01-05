require 'spec_helper'

describe Bosh::AwsCloud::Cloud do
  subject(:cloud) { described_class.new(options) }

  let(:options) { mock_cloud_options['properties'] }

  let(:az_selector) { instance_double('Bosh::AwsCloud::AvailabilityZoneSelector') }

  before do
    allow(Bosh::AwsCloud::AvailabilityZoneSelector).to receive(:new).and_return(az_selector)
    reg = Aws::EC2::Region.new('fake-region', endpoint: 'http://some.endpoint')
    allow_any_instance_of(Aws::EC2).to receive(:regions).and_return([reg])
  end

  describe '#initialize' do
    describe 'validating initialization options' do
      context 'when required options are missing' do
        let(:options) do
          {
              'plugin' => 'aws',
              'properties' => {}
          }
        end

        it 'raises an error' do

          expect { cloud }.to raise_error(
              ArgumentError,
              'missing configuration parameters > aws:default_key_name, aws:max_retries, registry:endpoint, registry:user, registry:password'
            )
        end
      end

      context 'when both region or endpoints are missing' do
        let(:options) do
          opts = mock_cloud_options['properties']
          opts['aws'].delete('region')
          opts['aws'].delete('ec2_endpoint')
          opts['aws'].delete('elb_endpoint')
          opts
        end
        it 'raises an error' do
          expect { cloud }.to raise_error(
              ArgumentError,
              'missing configuration parameters > aws:region, or aws:ec2_endpoint and aws:elb_endpoint'
            )
        end
      end

      context 'when all the required configurations are present' do
        it 'does not raise an error ' do
          expect { cloud }.to_not raise_error
        end
      end

      context 'when optional properties are not provided' do
        it 'default value is used for http properties' do
          expect(cloud.ec2_client.config.http_read_timeout).to eq(60)
          expect(cloud.ec2_client.config.http_wire_trace).to be false
          expect(cloud.ec2_client.config.ssl_verify_peer).to be true
        end
      end

      context 'when optional and required properties are provided' do
        let(:options) do
          mock_cloud_properties_merge(
              {
                  'aws' => {
                      'region' => 'fake-region'
                  }
              }
          )
        end

        it 'passes required properties to AWS SDK' do
          config = cloud.ec2_client.config
          expect(config.region).to eq('fake-region')
        end
      end

      context 'when the given region is invalid' do
        let(:regions) { instance_double(Aws::EC2::RegionCollection) }
        before do
          allow_any_instance_of(Aws::EC2).to receive(:regions).and_return(regions)
        end

        it 'raises a cloud error' do
          allow(regions).to receive(:first).and_raise(
            SocketError,
            'getaddrinfo: Name or service not known',
          )
          expect { cloud }.to raise_error(
            Bosh::Clouds::CloudError,
            /region.*getaddrinfo/m,
          )
        end
      end
    end
  end

  describe '#create_disk' do
    let(:cloud_properties) { {} }
    let(:volume) { instance_double('Aws::EC2::Volume', id: 'fake-volume-id') }

    before do
      allow(az_selector).to receive(:select_availability_zone).
        with(42).and_return('fake-availability-zone')
    end

    before do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_volume).with(volume: volume, state: :available)
    end

    context 'when volumes are set' do
      let(:ec2_client) { instance_double('Aws::EC2', client: low_level_client) }
      let(:low_level_client) { instance_double('Aws::EC2::Client::V20141001') }
      let(:volume_resp) { double('Aws::Core::Response', volume_id: 'fake-volume-id') }
      let(:volume) { double('Aws::EC2::Volume', id: 'fake-volume-id') }
      before do
        cloud.instance_variable_set(:'@ec2_client', ec2_client)
        allow(ec2_client).to receive(:config).and_return('fake-config')
        allow(Aws::EC2::Volume).to receive(:new_from)
          .with(:create_volume, volume_resp, 'fake-volume-id', config: 'fake-config')
          .and_return(volume)
      end

      context 'when disk type is provided' do
        let(:cloud_properties) { { 'type' => disk_type } }

        context 'when disk size is between 1 GiB and 16 TiB' do
          let(:disk_size) { 10240000 }

          context 'when disk type is gp2' do
            let(:disk_type) { 'gp2' }

            it 'creates disk with gp2 type' do
              expect(low_level_client).to receive(:create_volume).with(
                size: 10000,
                availability_zone: 'fake-availability-zone',
                volume_type: 'gp2',
                encrypted: false
              ).and_return(volume_resp)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end
          end

          context 'when disk type is io1' do
            let(:cloud_properties) { { 'type' => disk_type, 'iops' => 123 } }
            let(:disk_type) { 'io1' }

            it 'creates disk with io1 type' do
              expect(low_level_client).to receive(:create_volume).with(
                size: 10000,
                availability_zone: 'fake-availability-zone',
                volume_type: 'io1',
                iops: 123,
                encrypted: false
              ).and_return(volume_resp)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end
          end
        end

        context 'when disk size is between 1 GiB and 1 TiB' do
          let(:disk_size) { 1025 }

          context 'when disk type is specified' do
            let(:disk_type) { 'standard' }

            it 'creates disk with the specified type' do
              expect(low_level_client).to receive(:create_volume).with(
                size: 2,
                availability_zone: 'fake-availability-zone',
                volume_type: 'standard',
                encrypted: false
              ).and_return(volume_resp)
              cloud.create_disk(disk_size, cloud_properties, 42)
            end
          end
        end
      end

      context 'when disk type is not provided' do
        let(:cloud_properties) { {} }
        let(:disk_size) { 1025 }

        it 'creates disk with gp2 disk type' do
          expect(low_level_client).to receive(:create_volume).with(
            size: 2,
            availability_zone: 'fake-availability-zone',
            volume_type: 'gp2',
            encrypted: false
          ).and_return(volume_resp)
          cloud.create_disk(disk_size, cloud_properties, 42)
        end
      end
    end
  end

  describe 'validating credentials_source' do
    context 'when credentials_source is set to static' do

      context 'when access_key_id and secret_access_key are omitted' do
        let(:options) do
          mock_cloud_properties_merge(
              {
                  'aws' => {
                      'credentials_source' => 'static',
                      'access_key_id' => nil,
                      'secret_access_key' => nil
                  }
              }
          )
        end
        it 'raises an error' do
          expect { cloud }.to raise_error(
          ArgumentError,
          'Must use access_key_id and secret_access_key with static credentials_source'
          )
        end
      end
    end

    context 'when credentials_source is set to env_or_profile' do
      let(:options) do
        mock_cloud_properties_merge(
            {
                'aws' => {
                    'credentials_source' => 'env_or_profile',
                    'access_key_id' => nil,
                    'secret_access_key' => nil
                }
            }
        )
      end
      it 'does not raise an error ' do
        expect { cloud }.to_not raise_error
      end
    end

    context 'when credentials_source is set to env_or_profile and access_key_id is provided' do
      let(:options) do
        mock_cloud_properties_merge(
            {
                'aws' => {
                    'credentials_source' => 'env_or_profile',
                    'access_key_id' => 'some access key'
                }
            }
        )
      end
      it 'raises an error' do
        expect { cloud }.to raise_error(
        ArgumentError,
        "Can't use access_key_id and secret_access_key with env_or_profile credentials_source"
        )
      end
    end

    context 'when an unknown credentails_source is set' do
      let(:options) do
        mock_cloud_properties_merge(
            {
                'aws' => {
                    'credentials_source' => 'NotACredentialsSource'
                }
            }
        )
      end

      it 'raises an error' do
        expect { cloud }.to raise_error(
        ArgumentError,
        'Unknown credentials_source NotACredentialsSource'
        )
      end
    end
  end

  describe '#configure_networks' do
    it 'raises a NotSupported exception' do
      expect {
        cloud.configure_networks("i-foobar", {})
      }.to raise_error Bosh::Clouds::NotSupported
    end
  end
end
