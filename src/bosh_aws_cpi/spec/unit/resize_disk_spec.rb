require "spec_helper"

describe Bosh::AwsCloud::CloudV1, "resize_disk" do
  let(:volume_manager) { instance_double(Bosh::AwsCloud::VolumeManager) }
  let(:volume) { instance_double(Aws::EC2::Volume, :id => 'disk-id') }
  let(:volume_resp) { instance_double(Aws::EC2::Types::ModifyVolumeResult, :volume_modification => {modification_state: 'completed'}) }

  before do
    @cloud = mock_cloud do |_ec2|
      @ec2 = _ec2
      allow(@ec2).to receive(:config).and_return('fake-config')
      allow(@ec2).to receive(:volume).with("disk-id").and_return(volume)
    end
    allow(volume).to receive(:size).and_return(2)
    allow(volume).to receive(:attachments).and_return([])
    allow(@ec2.client).to receive(:modify_volume).and_return(volume_resp)
    modification = instance_double(Bosh::AwsCloud::SdkHelpers::VolumeModification, :state => 'completed')
    allow(Bosh::AwsCloud::SdkHelpers::VolumeModification).to receive(:new).with(volume, volume_resp.volume_modification, @ec2.client).and_return(modification)
    allow(Bosh::AwsCloud::ResourceWait).to receive(:for_volume_modification).with(volume_modification: modification, state: 'completed')
  end


  it 'uses the AWS endpoint to resize a disk' do
    allow(Bosh::Clouds::Config.logger).to receive(:info)
    return_value = @cloud.resize_disk('disk-id', 4096)

    expect(return_value).to eq(nil)

    expect(@ec2.client).to have_received(:modify_volume).with(volume_id: 'disk-id',size: 4)
    expect(Bosh::Clouds::Config.logger).to have_received(:info).with('Disk disk-id resized from 2 GiB to 4 GiB')
  end

  context 'when trying to resize to the same disk size' do
    it 'does not call extend on disk and writes to the log' do
      allow(Bosh::Clouds::Config.logger).to receive(:info)

      @cloud.resize_disk('disk-id', 2048)

      expect(Bosh::Clouds::Config.logger).to have_received(:info).with('Skipping resize of disk disk-id because current value 2 GiB is equal new value 2 GiB')
    end
  end

  context 'when trying to resize disk to a new size with an not even size in MiB' do
    it 'does not call extend on disk and writes to the log' do
      allow(volume).to receive(:extend)
      allow(Bosh::Clouds::Config.logger).to receive(:info)

      @cloud.resize_disk('disk-id', 4097)

      expect(@ec2.client).to have_received(:modify_volume).with(volume_id: 'disk-id',size: 5)
      expect(Bosh::Clouds::Config.logger).to have_received(:info).with('Disk disk-id resized from 2 GiB to 5 GiB')
    end
  end

  context 'when trying to resize a non existing disk' do
    it 'fails' do
      allow(@ec2).to receive(:volume).with('non-existing-disk-id').and_return(nil)
      expect {
        @cloud.resize_disk('non-existing-disk-id', 1024)
      }.to raise_error(Bosh::Clouds::CloudError, 'Cannot resize volume because volume with non-existing-disk-id not found')
    end
  end

  context 'when trying to resize to a smaller disk' do
    it 'fails' do
      expect {
        @cloud.resize_disk('disk-id', 1024)
      }.to raise_error(Bosh::Clouds::CloudError, 'Cannot resize volume to a smaller size from 2 GiB to 1 GiB')
    end
  end

  context 'when volume is still attached' do
    before do
      allow(volume).to receive(:attachments).and_return([{}])
    end

    it 'fails' do
      expect {
        @cloud.resize_disk('disk-id', 4096)
      }.to raise_error(Bosh::Clouds::CloudError, "Cannot resize volume 'disk-id' it still has 1 attachment(s)")
    end
  end
end
