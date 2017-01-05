require "spec_helper"

describe Bosh::AwsCloud::AvailabilityZoneSelector do

  let(:instances) { double(Aws::EC2::InstanceCollection) }
  let(:instance) { double(Aws::EC2::Instance, :availability_zone => 'this_zone') }
  let(:us_east_1a) { double(Aws::EC2::AvailabilityZone, name: 'us-east-1a') }
  let(:us_east_1b) { double(Aws::EC2::AvailabilityZone, name: 'us-east-1b') }
  let(:zones) { [us_east_1a, us_east_1b] }
  let(:region) { double(Aws::EC2::Region, :instances => instances, :availability_zones => zones) }
  let(:subject) { described_class.new(region) }

  describe '#common_availability_zone' do
    it 'should raise an error when multiple availability zones are present and volume information is passed in' do
      expect {
        subject.common_availability_zone(%w[this_zone that_zone], 'other_zone', 'another_zone')
      }.to raise_error Bosh::Clouds::CloudError, "can't use multiple availability zones: subnet in another_zone, VM in other_zone, and volume in this_zone, that_zone"
    end

    it 'should raise an error when multiple availability zones are present and no volume information is passed in' do
      expect {
        subject.common_availability_zone([], 'other_zone', 'another_zone')
      }.to raise_error Bosh::Clouds::CloudError, "can't use multiple availability zones: subnet in another_zone, VM in other_zone"
    end

    it 'should select the common availability zone' do
      expect(subject.common_availability_zone(%w(this_zone), 'this_zone', nil)).to eq('this_zone')
    end
  end

  describe '#select_availability_zone' do
    context 'without a default' do
      let(:subject) { described_class.new(region) }

      context 'with a instance id' do
        it 'should return the az of the instance' do
          allow(instances).to receive(:[]).and_return(instance)

          expect(subject.select_availability_zone(instance)).to eq('this_zone')
        end
      end

      context 'without a instance id' do
        it 'should return a random az' do
          allow(Random).to receive_messages(:rand => 0)
          expect(subject.select_availability_zone(nil)).to eq('us-east-1a')
        end
      end
    end
  end
end
