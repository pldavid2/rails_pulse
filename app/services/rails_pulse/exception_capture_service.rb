module RailsPulse
  class ExceptionCaptureService
    APP_FRAME_PATTERN = %r{/app/}
    GEM_FRAME_PATTERN = %r{/gems/|/rubygems/|/bundler/|/ruby/}

    PARAMS_SIZE_LIMIT = 10_240 # 10KB

    # Enhanced: accept extra context from our middleware integration
    def self.capture(exception, request_url: nil, request_method: nil, request_params: nil,
                     environment: nil, deploy_sha: nil, local_variables: nil, custom_context: nil,
                     request_headers: nil, user_agent: nil, ip_address: nil, session_id: nil,
                     user: nil)
      new(exception, request_url: request_url, request_method: request_method,
          request_params: request_params, environment: environment, deploy_sha: deploy_sha,
          local_variables: local_variables, custom_context: custom_context,
          request_headers: request_headers, user_agent: user_agent, ip_address: ip_address,
          session_id: session_id, user: user).capture
    end

    def initialize(exception, request_url: nil, request_method: nil, request_params: nil,
                   environment: nil, deploy_sha: nil, local_variables: nil, custom_context: nil,
                   request_headers: nil, user_agent: nil, ip_address: nil, session_id: nil,
                   user: nil)
      @exception = exception
      @request_url = request_url
      @request_method = request_method
      @request_params = request_params
      @environment = environment || Rails.env.to_s
      @deploy_sha = deploy_sha
      @local_variables = local_variables
      @custom_context = custom_context
      @request_headers = request_headers
      @user_agent = user_agent
      @ip_address = ip_address
      @session_id = session_id
      @user = user
    end

    def capture
      return unless RailsPulse.configuration.track_exceptions
      return if RequestStore.store[:skip_recording_rails_pulse_activity]

      config = RailsPulse.configuration

      # Check ignored exceptions
      return if config.exception_tracking[:ignored_classes].include?(@exception.class.name)

      # Before track callback
      if config.exception_tracking[:before_track]
        result = config.exception_tracking[:before_track].call(@exception, {})
        return if result == false
      end

      frames = parse_backtrace(@exception.backtrace || [])
      fingerprint = compute_fingerprint(@exception.class.name, frames)
      now = Time.current

      group = upsert_group(fingerprint, frames, now)
      occurrence = create_occurrence(group, frames, now)

      # Notify if needed
      if should_notify?(group)
        notify(group, occurrence)
      end

      # After track callback
      config.exception_tracking[:after_track]&.call(group, occurrence)

      occurrence
    rescue => e
      Rails.logger.error("[RailsPulse] ExceptionCaptureService error: #{e.message}")
      nil
    end

    private

    def parse_backtrace(raw_backtrace)
      limit = RailsPulse.configuration.exception_tracking[:backtrace_lines_limit] || 50
      raw_backtrace.first(limit).filter_map do |line|
        match = line.match(/\A(.+):(\d+):in ['`](.+)'?\z/)
        next unless match
        { file: match[1], line: match[2].to_i, method: match[3] }
      end
    end

    def first_app_frame(frames)
      frames.find { |f| f[:file].match?(APP_FRAME_PATTERN) && !f[:file].match?(GEM_FRAME_PATTERN) }
    end

    def compute_fingerprint(exception_class, frames)
      frame = first_app_frame(frames)
      location = frame ? "#{frame[:file]}:#{frame[:line]}" : "unknown"
      Digest::SHA256.hexdigest("#{exception_class}:#{location}")
    end

    def upsert_group(fingerprint, frames, now)
      group = ExceptionGroup.find_or_initialize_by(fingerprint: fingerprint)
      was_resolved = group.persisted? && group.status == "resolved"

      group.exception_class  = @exception.class.name
      group.message          = @exception.message.to_s.truncate(500)
      group.first_seen_at  ||= now
      group.last_seen_at     = now

      # Store source location for display in list views
      if group.respond_to?(:source_location=)
        frame = first_app_frame(frames)
        if frame
          path = frame[:file].to_s.sub(%r{.*/(?=app/|lib/|config/)}, "")
          group.source_location = "#{path}:#{frame[:line]}"
        end
      end

      # Reopen resolved groups
      if was_resolved
        group.status = "unresolved"
        group.resolved_at = nil
      end

      group.save!

      ExceptionGroup.where(id: group.id).update_counters(occurrence_count: 1)
      group.reload
    rescue ActiveRecord::RecordNotUnique
      group = ExceptionGroup.find_by!(fingerprint: fingerprint)
      ExceptionGroup.where(id: group.id).update_counters(occurrence_count: 1)
      group.update!(last_seen_at: now)
      group.reload
    end

    def current_deploy_sha
      @current_deploy_sha ||= RailsPulse::Deployment.order(started_at: :desc).first&.revision
    end

    def filtered_params
      return nil unless RailsPulse.configuration.exception_tracking[:capture_params]
      return nil if @request_params.blank?

      params_hash = @request_params.respond_to?(:to_unsafe_h) ? @request_params.to_unsafe_h : @request_params.to_h
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      filtered = filter.filter(params_hash)

      serialized = filtered.to_json
      serialized.bytesize <= PARAMS_SIZE_LIMIT ? filtered : nil
    end

    def filtered_headers
      return nil if @request_headers.blank?
      safe_headers = %w[HTTP_ACCEPT HTTP_ACCEPT_LANGUAGE HTTP_HOST HTTP_REFERER REQUEST_METHOD
                        HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP CONTENT_TYPE]
      result = {}
      @request_headers.each do |key, value|
        key_s = key.to_s
        next unless key_s.start_with?("HTTP_", "CONTENT_", "REQUEST_")
        result[key_s] = value.to_s.truncate(500) if safe_headers.include?(key_s)
      end
      result.to_json
    rescue
      nil
    end

    def create_occurrence(group, frames, now)
      ExceptionOccurrence.create!(
        exception_group: group,
        exception_class: @exception.class.name,
        message:         @exception.message.to_s.truncate(500),
        backtrace:       frames,
        request_url:     @request_url,
        request_method:  @request_method,
        request_params:  filtered_params,
        environment:     @environment,
        deploy_sha:      @deploy_sha || current_deploy_sha,
        occurred_at:     now,
        # Our additions
        local_variables: @local_variables.is_a?(Hash) ? @local_variables.to_json : @local_variables,
        custom_context:  @custom_context.is_a?(Hash) ? @custom_context.to_json : @custom_context,
        request_headers: filtered_headers,
        user_agent:      @user_agent.to_s.truncate(500).presence,
        ip_address:      @ip_address,
        session_id:      @session_id,
        user_id:         @user&.id,
        user_type:       @user&.class&.name,
        hostname:        Socket.gethostname,
        process_id:      Process.pid.to_s
      )
    end

    # Notification support
    def should_notify?(group)
      config = RailsPulse.configuration
      return false unless config.notifications[:enabled]
      return false unless config.exception_tracking[:notify]
      rules = config.notifications[:rules]
      return false unless rules
      return false unless rules[:environments]&.include?(Rails.env)
      return false if config.notifications[:channels].empty?

      if config.notifications[:cooldown] && group.last_notified_at
        return false if group.last_notified_at > config.notifications[:cooldown].ago
      end

      return true if rules[:on_first_occurrence] && group.occurrence_count == 1
      return true if rules[:on_reopen] && group.recently_reopened?
      return true if rules[:on_threshold]&.include?(group.occurrence_count)
      return true if rules[:critical_classes]&.include?(group.exception_class)

      false
    end

    def notify(group, occurrence)
      config = RailsPulse.configuration
      config.notifications[:channels].each do |notifier|
        next unless notifier.should_notify?(group, occurrence)
        notifier.call(group, occurrence)
      rescue => e
        Rails.logger.error("[RailsPulse] Notifier #{notifier.class} failed: #{e.message}")
      end
      group.update_column(:last_notified_at, Time.current)
    end
  end
end
