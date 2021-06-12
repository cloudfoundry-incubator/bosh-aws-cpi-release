require_relative 'helpers'

module Bosh::AwsCloud
  class ResourceWait
    include Helpers

    # a sane amount of retries on AWS (~25 minutes),
    # as things can take anywhere between a minute and forever
    DEFAULT_TRIES = 54
    MAX_SLEEP_TIME = 15
    DEFAULT_WAIT_ATTEMPTS = 600 / MAX_SLEEP_TIME # 10 minutes

    def self.for_attachment(args)
      attachment = args.fetch(:attachment) { raise ArgumentError, 'attachment object required' }
      target_state = args.fetch(:state) { raise ArgumentError, 'state symbol required' }
      valid_states = ['attached', 'detached']
      validate_states(valid_states, target_state)

      ignored_errors = []
      if target_state == 'attached'
        ignored_errors << Aws::EC2::Errors::InvalidVolumeNotFound
        ignored_errors << Aws::EC2::Errors::ResourceNotFound
      end
      description = "volume %s to be %s to instance %s as device %s" % [attachment.volume.id, target_state, attachment.instance.id, attachment.device]

      new.for_resource(resource: attachment, errors: ignored_errors, target_state: target_state, description: description) do |current_state|
        current_state == target_state
      end
    rescue Aws::EC2::Errors::InvalidVolumeNotFound, Aws::EC2::Errors::ResourceNotFound
      # if an attachment is detached, AWS can reap the object and the reference is no longer found,
      # so consider this exception a success condition if we are detaching
      raise unless target_state == 'detached'
    end

    def self.for_image(args)
      image = args.fetch(:image) { raise ArgumentError, 'image object required' }
      target_state = args.fetch(:state) { raise ArgumentError, 'state symbol required' }
      valid_states = ['available', 'deregistered']
      validate_states(valid_states, target_state)

      ignored_errors = []
      if target_state == 'available'
        ignored_errors << Aws::EC2::Errors::InvalidAMIIDNotFound
        ignored_errors << Aws::EC2::Errors::ResourceNotFound
      end

      new.for_resource(resource: image, errors: ignored_errors, target_state: target_state) do |current_state|
        current_state == target_state
      end
    rescue Aws::EC2::Errors::InvalidAMIIDNotFound, Aws::EC2::Errors::ResourceNotFound
      raise unless target_state == 'deregistered'
    end

    def self.for_volume(args)
      volume = args.fetch(:volume) { raise ArgumentError, 'volume object required' }
      target_state = args.fetch(:state) { raise ArgumentError, 'state symbol required' }
      valid_states = ['available', 'deleted']
      validate_states(valid_states, target_state)

      ignored_errors = []
      if target_state == 'available'
        ignored_errors << Aws::EC2::Errors::InvalidVolumeNotFound
        ignored_errors << Aws::EC2::Errors::ResourceNotFound
      end

      new.for_resource(resource: volume, target_state: target_state) do |current_state|
        current_state == target_state
      end
    rescue Aws::EC2::Errors::InvalidVolumeNotFound, Aws::EC2::Errors::ResourceNotFound
      # if an volume is deleted, AWS can reap the object and the reference is no longer found,
      # so consider this exception a success condition if we are deleting
      raise unless target_state == 'deleted'
    end

    def self.for_volume_modification(args)
      volume_modification = args.fetch(:volume_modification) { raise ArgumentError, 'volume_modification object required' }
      target_state = args.fetch(:state) { raise ArgumentError, 'state symbol required' }
      valid_states = ['modifying', 'optimizing', 'completed', 'failed']
      validate_states(valid_states, target_state)

      ignored_errors = []
      if target_state == 'completed'
        ignored_errors << Aws::EC2::Errors::InvalidVolumeNotFound
        ignored_errors << Aws::EC2::Errors::ResourceNotFound
      end
      description = "volume modification of %s current state %s" % [volume_modification.volume.id, volume_modification.state]

      new.for_resource(resource: volume_modification, errors: ignored_errors, target_state: target_state, description: description) do |current_state|
        current_state == target_state
      end

    rescue Aws::EC2::Errors::InvalidVolumeNotFound, Aws::EC2::Errors::ResourceNotFound
      raise unless target_state == 'failed'
    end

    def self.for_snapshot(args)
      snapshot = args.fetch(:snapshot) { raise ArgumentError, 'snapshot object required' }
      target_state = args.fetch(:state) { raise ArgumentError, 'state symbol required' }
      valid_states = ['completed']
      validate_states(valid_states, target_state)

      new.for_resource(resource: snapshot, target_state: target_state) do |current_state|
        current_state == target_state
      end
    end

    def self.validate_states(valid_states, target_state)
      unless valid_states.include?(target_state)
        raise ArgumentError, "target state must be one of #{valid_states.join(', ')}, `#{target_state}' given"
      end
    end

    def self.sleep_callback(description, options)
      max_sleep_time = options.fetch(:max, MAX_SLEEP_TIME)
      lambda do |num_tries, error|
        if options[:tries_before_max] && num_tries >= options[:tries_before_max]
          time = max_sleep_time
        else
          if options[:exponential]
            time = [options[:interval] ** num_tries, max_sleep_time].min
          else
            time = [1 + options[:interval] * num_tries, max_sleep_time].min
          end
        end
        Bosh::AwsCloud::ResourceWait.logger.debug("#{error.class}: `#{error.message}'") if error
        Bosh::AwsCloud::ResourceWait.logger.debug("#{description}, retrying in #{time} seconds (#{num_tries}/#{options[:total]})")
        time
      end
    end

    def self.logger
      Bosh::Clouds::Config.logger
    end

    def initialize
      @started_at = Time.now
    end

    def for_resource(args, &blk)
      resource = args.fetch(:resource)
      errors = args.fetch(:errors, [])
      desc = args.fetch(:description) { resource.id }
      tries = args.fetch(:tries, DEFAULT_TRIES).to_i
      target_state = args.fetch(:target_state)

      sleep_cb = self.class.sleep_callback(
        "Waiting for #{desc} to be #{target_state}",
        { interval: 2, total: tries, max: 32, exponential: true }
      )
      ensure_cb = Proc.new do |retries|
        cloud_error("Timed out waiting for #{desc} to be #{target_state}, took #{time_passed}s") if retries == tries
      end

      errors << Aws::EC2::Errors::RequestLimitExceeded

      state = nil
      Bosh::Retryable.new(tries: tries, sleep: sleep_cb, on: errors, ensure: ensure_cb).retryer do
        resource.reload

        if resource.data.nil?
          raise Aws::EC2::Errors::ResourceNotFound.new(nil, "Waiting for #{desc} to be #{target_state}") unless resource.exists?
        end

        s = resource.state
        state = s.is_a?(String) ? s : s.name

        # check all cases where state can be error or failed
        if state == 'error' || state == 'failed'
          raise Bosh::Clouds::CloudError, "#{desc} state is #{state}, expected #{target_state}, took #{time_passed}s"
        end

        # the yielded block should return true if we have reached the target state
        blk.call(state)
      end

      Bosh::AwsCloud::ResourceWait.logger.info("#{desc} is now #{state}, took #{time_passed}s")
    rescue Bosh::Common::RetryCountExceeded => e
      Bosh::AwsCloud::ResourceWait.logger.error(
        "Timed out waiting for #{desc} state is #{state}, expected to be #{target_state}, took #{time_passed}s")
      raise e
    end

    def time_passed
      Time.now - @started_at
    end
  end
end
