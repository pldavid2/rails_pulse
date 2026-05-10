module RailsPulse
  module Middleware
    class RequestCollector
      def initialize(app)
        @app = app
      end

      def call(env)
        # Skip if Rails Pulse is disabled
        return @app.call(env) unless RailsPulse.configuration.enabled

        # Skip logging if we are already recording RailsPulse activity. This is to avoid recursion issues
        return @app.call(env) if RequestStore.store[:skip_recording_rails_pulse_activity]

        req = ActionDispatch::Request.new(env)

        # Skip RailsPulse engine requests
        mount_path = RailsPulse.configuration.mount_path || "/rails_pulse"
        if req.path.start_with?(mount_path)
          return with_recording_suppressed { @app.call(env) }
        end

        # Check if route should be ignored based on configuration
        if should_ignore_route?(req)
          return with_recording_suppressed { @app.call(env) }
        end

        # Clear any previous request data and set a placeholder ID
        RequestStore.store[:rails_pulse_request_id] = SecureRandom.uuid
        RequestStore.store[:rails_pulse_operations] = []

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        controller_action = "#{env['action_dispatch.request.parameters']&.[]('controller')&.classify}##{env['action_dispatch.request.parameters']&.[]('action')}"
        occurred_at = Time.current

        # Process request with optional TracePoint capture for error tracking
        middleware_capture = RailsPulse.configuration.track_exceptions &&
                             RailsPulse.configuration.exception_tracking[:capture_method] == :middleware
        status, headers, response = if middleware_capture
          RailsPulse::TracepointCapture.with_capture { @app.call(env) }
        else
          @app.call(env)
        end
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)

        # Collect all tracking data
        # Deep copy operations array to prevent race condition in async mode
        operations = RequestStore.store[:rails_pulse_operations] || []
        detect_n_plus_one(operations)
        tracking_data = {
          method: req.request_method,
          path: req.path,
          duration: duration,
          status: status,
          is_error: status.to_i >= 500,
          request_uuid: req.uuid,
          controller_action: controller_action,
          occurred_at: occurred_at,
          response_size_bytes: response_size_bytes(headers, response),
          operations: operations.map(&:dup)
        }

        # Send to tracker (non-blocking if async mode enabled)
        RailsPulse::Tracker.track_request(tracking_data)

        [ status, headers, response ]
      rescue Exception => exception
        # Track the error via middleware (only if middleware capture is active)
        if middleware_capture && !should_ignore_error?(exception, env)
          track_error(exception, env)
        end
        raise
      ensure
        RailsPulse::TracepointCapture.clear if middleware_capture
        RequestStore.store[:skip_recording_rails_pulse_activity] = false
        RequestStore.store[:rails_pulse_request_id] = nil
        RequestStore.store[:rails_pulse_operations] = nil
      end

      private

      def with_recording_suppressed
        RequestStore.store[:skip_recording_rails_pulse_activity] = true
        yield
      ensure
        RequestStore.store[:skip_recording_rails_pulse_activity] = false
      end

      def response_size_bytes(headers, response)
        return headers["Content-Length"].to_i if headers["Content-Length"]
        body = response.respond_to?(:body) ? response.body : nil
        body.bytesize if body.is_a?(String)
      rescue
        nil
      end

      def detect_n_plus_one(operations)
        sql_ops = operations.select { |op| op[:operation_type] == "sql" }
        return if sql_ops.size < 2

        groups = sql_ops.group_by { |op| RailsPulse::SqlQueryNormalizer.normalize(op[:label].to_s) }
        groups.each do |normalized_sql, ops|
          next if ops.size < 2
          ops.each do |op|
            op[:repeated_query_group] = normalized_sql
            op[:repetition_count] = ops.size
          end
        end
      end

      def should_ignore_route?(req)
        # Get ignored routes from configuration
        ignored_routes = RailsPulse.configuration.ignored_routes || []

        # Create route identifier for matching
        route_method_path = "#{req.request_method} #{req.path}"
        route_path = req.path

        # Check each ignored route pattern
        ignored_routes.any? do |pattern|
          case pattern
          when String
            # Exact string match against path or method+path
            pattern == route_path || pattern == route_method_path
          when Regexp
            # Regex match against path or method+path
            pattern.match?(route_path) || pattern.match?(route_method_path)
          else
            false
          end
        end
      end

      def should_ignore_error?(exception, env)
        path = env["PATH_INFO"].to_s
        RailsPulse.configuration.exception_tracking[:middleware_ignore_paths].any? { |p| path.start_with?(p) }
      end

      def track_error(exception, env)
        request = ActionDispatch::Request.new(env)
        user = extract_error_user(env)
        custom_data = extract_custom_error_data(env, request)

        RailsPulse::ExceptionCaptureService.capture(
          exception,
          request_url: request.original_url.to_s.truncate(2000),
          request_method: request.method,
          request_params: request.params,
          environment: Rails.env.to_s,
          local_variables: RailsPulse::TracepointCapture.captured_locals,
          custom_context: custom_data.presence,
          request_headers: request.headers,
          user_agent: request.user_agent,
          ip_address: request.remote_ip,
          session_id: request.session&.id&.to_s,
          user: user
        )
      rescue => e
        Rails.logger.error "[RailsPulse] Error tracking failed: #{e.message}"
      end

      def extract_error_user(env)
        # Try Warden (Devise)
        if env["warden"]&.user
          return env["warden"].user
        end

        # Try controller context
        if env["action_controller.instance"]
          controller = env["action_controller.instance"]
          method = RailsPulse.configuration.exception_tracking[:user_method]

          if method && controller.respond_to?(method, true)
            return controller.send(method)
          end
        end

        nil
      rescue
        nil
      end

      def extract_custom_error_data(env, request)
        config = RailsPulse.configuration

        if config.exception_tracking[:custom_context]
          config.exception_tracking[:custom_context].call(request, env)
        else
          {}
        end
      rescue
        {}
      end
    end
  end
end
