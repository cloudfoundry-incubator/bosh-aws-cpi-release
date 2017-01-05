require 'spec_helper'

describe Bosh::AwsCloud::SpotManager do
  let(:spot_manager) { described_class.new(ec2) }
  let(:ec2) { instance_double(Aws::EC2) }
  let(:aws_client) { instance_double("#{Aws::EC2::Client.new.class}") }
  let(:fake_instance_params) { { fake: 'params' } }

  before do
    allow(ec2).to receive(:client).and_return(aws_client)
    allow(aws_client).to receive(:request_spot_instances).and_return(spot_instance_requests)
    allow(aws_client).to receive(:describe_spot_instance_requests).and_return({
      spot_instance_request_set: [{
        instance_id: 'i-12345678',
        state: 'active'
      }]
    })
  end

  let(:spot_instance_requests) do
    {
      spot_instance_request_set: [
        { spot_instance_request_id: 'sir-12345c' }
      ],
      request_id: 'request-id-12345'
    }
  end

  before { allow(ec2).to receive(:instances).and_return( {'i-12345678' => instance } ) }
  let(:instance) { double(Aws::EC2::Instance, id: 'i-12345678') }

  # Override total_spot_instance_request_wait_time to be "unit test" speed
  before { stub_const('Bosh::AwsCloud::SpotManager::TOTAL_WAIT_TIME_IN_SECONDS', 0.1) }

  it 'request sends AWS request for spot instance' do
    expect(aws_client).to receive(:request_spot_instances).with({
      spot_price: '0.24',
      instance_count: 1,
      launch_specification: { fake: 'params' }
    }).and_return(spot_instance_requests)

    expect(spot_manager.create(fake_instance_params, 0.24)).to be(instance)
  end

  it 'fails to create the spot instance if instance_params[:security_group] is set' do
    invalid_instance_params = { fake: 'params', security_groups: ['sg-name'] }
    expect(Bosh::Clouds::Config.logger).to receive(:error).with(/Cannot use security group names when creating spot instances/)
    expect{
      spot_manager.create(invalid_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed, /Cannot use security group names when creating spot instances/) { |error|
      expect(error.ok_to_retry).to eq false
    }
  end

  it 'should fail to return an instance when starting a spot instance times out' do
    spot_instance_requests = {
      spot_instance_request_set: [
        { spot_instance_request_id: 'sir-12345c' }
      ],
      request_id: 'request-id-12345'
    }

    expect(aws_client).to receive(:describe_spot_instance_requests).
      exactly(Bosh::AwsCloud::SpotManager::RETRY_COUNT).times.with({ spot_instance_request_ids: ['sir-12345c'] }).
      and_return({ spot_instance_request_set: [{ state: 'open' }] })

    # When erroring, should cancel any pending spot requests
    expect(aws_client).to receive(:cancel_spot_instance_requests)

    expect {
      spot_manager.create(fake_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
      expect(error.ok_to_retry).to eq false
    }
  end

  it 'should retry checking spot instance request state when Aws::EC2::Errors::InvalidSpotInstanceRequestID::NotFound raised' do
    #Simulate first recieving an error when asking for spot request state
    expect(aws_client).to receive(:describe_spot_instance_requests).
      with({ spot_instance_request_ids: ['sir-12345c'] }).
      and_raise(Aws::EC2::Errors::InvalidSpotInstanceRequestID::NotFound)
    expect(aws_client).to receive(:describe_spot_instance_requests).
      with({ spot_instance_request_ids: ['sir-12345c'] }).
      and_return({ spot_instance_request_set: [{ state: 'active', instance_id: 'i-12345678' }] })

    #Shouldn't cancel spot request when things succeed
    expect(aws_client).to_not receive(:cancel_spot_instance_requests)

    expect {
      spot_manager.create(fake_instance_params, 0.24)
    }.to_not raise_error
  end

  it 'should immediately fail to return an instance when spot bid price is too low' do
    expect(aws_client).to receive(:describe_spot_instance_requests).
      exactly(1).times.
      with({ spot_instance_request_ids: ['sir-12345c'] }).
      and_return(
      {
        spot_instance_request_set: [{
          instance_id: 'i-12345678',
          state: 'open',
          status: { code: 'price-too-low' }
        }]
      }
    )

    # When erroring, should cancel any pending spot requests
    expect(aws_client).to receive(:cancel_spot_instance_requests)

    expect {
      spot_manager.create(fake_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
      expect(error.ok_to_retry).to eq false
    }
  end

  it 'should fail VM creation (no retries) when spot request status == failed' do
    expect(aws_client).to receive(:describe_spot_instance_requests).
      with({ spot_instance_request_ids: ['sir-12345c'] }).
      and_return({
      spot_instance_request_set: [{
        instance_id: 'i-12345678',
        state: 'failed'
      }]
    })

    # When erroring, should cancel any pending spot requests
    expect(aws_client).to receive(:cancel_spot_instance_requests)

    expect {
      spot_manager.create(fake_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
      expect(error.ok_to_retry).to eq false
    }
  end

  it 'should fail VM creation and log an error when there is a CPI error' do
    aws_error = Aws::EC2::Errors::InvalidParameterValue.new(%q{price "0.3" exceeds your maximum Spot price limit of "0.24"})
    allow(aws_client).to receive(:request_spot_instances).and_raise(aws_error)

    expect(Bosh::Clouds::Config.logger).to receive(:error).with(/Failed to get spot instance request/)

    expect {
      spot_manager.create(fake_instance_params, 0.24)
    }.to raise_error(Bosh::Clouds::VMCreationFailed) { |error|
      expect(error.ok_to_retry).to eq false
      expect(error.message).to include("Failed to get spot instance request")
      expect(error.message).to include(aws_error.inspect)
    }
  end
end
