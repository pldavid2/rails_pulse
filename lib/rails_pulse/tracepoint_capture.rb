# frozen_string_literal: true

module RailsPulse
  # Dual TracePoint mechanism for capturing local variables at exception raise sites.
  # Uses :line tracer to track app-code bindings and :raise tracer to capture locals.
  module TracepointCapture
      THREAD_LOCAL_KEY = :rails_pulse_captured_locals
      THREAD_APP_BINDING_KEY = :rails_pulse_last_app_binding

      class << self
        def with_capture
          return yield unless RailsPulse.configuration.exception_tracking[:capture_local_variables]
          return yield unless should_capture_this_request?

          line_tracer = TracePoint.new(:line) do |tp|
            track_app_binding(tp)
          end

          raise_tracer = TracePoint.new(:raise) do |tp|
            capture_local_variables(tp)
          end

          line_tracer.enable do
            raise_tracer.enable { yield }
          end
        end

        def captured_locals
          data = Thread.current[THREAD_LOCAL_KEY]
          return nil unless data

          VariableSerializer.serialize(data[:locals])
        end

        def clear
          Thread.current[THREAD_LOCAL_KEY] = nil
          Thread.current[THREAD_APP_BINDING_KEY] = nil
        end

        private

        def should_capture_this_request?
          rate = RailsPulse.configuration.exception_tracking[:tracepoint_sample_rate]
          return true if rate >= 1.0
          rand < rate
        end

        def track_app_binding(tp)
          path = tp.path.to_s
          return if path.include?("/gems/") || path.include?("/ruby/")
          return if path.start_with?("<")

          binding_obj = tp.binding
          return unless binding_obj

          Thread.current[THREAD_APP_BINDING_KEY] = {
            binding: binding_obj,
            path: path,
            lineno: tp.lineno,
            method_id: tp.method_id
          }
        rescue StandardError
          # Silently ignore to avoid performance impact
        end

        def capture_local_variables(tp)
          path = tp.path.to_s
          in_app_code = !path.include?("/gems/") && !path.include?("/ruby/") && !path.start_with?("<")

          if in_app_code
            capture_from_tracepoint(tp)
          else
            capture_from_last_app_binding
          end
        rescue StandardError
          # Silently ignore
        end

        def capture_from_tracepoint(tp)
          binding_obj = tp.binding
          return unless binding_obj

          locals = extract_locals_from_binding(binding_obj)
          Thread.current[THREAD_LOCAL_KEY] = {
            locals: locals,
            path: tp.path.to_s,
            lineno: tp.lineno,
            method_id: tp.method_id
          }
        end

        def capture_from_last_app_binding
          app_binding_data = Thread.current[THREAD_APP_BINDING_KEY]
          return unless app_binding_data

          binding_obj = app_binding_data[:binding]
          return unless binding_obj

          locals = extract_locals_from_binding(binding_obj)
          Thread.current[THREAD_LOCAL_KEY] = {
            locals: locals,
            path: app_binding_data[:path],
            lineno: app_binding_data[:lineno],
            method_id: app_binding_data[:method_id]
          }
        end

        def extract_locals_from_binding(binding_obj)
          locals = {}
          binding_obj.local_variables.each do |var|
            locals[var] = binding_obj.local_variable_get(var)
          rescue StandardError
            locals[var] = "[Error accessing variable]"
          end
          locals
        end
      end
    end
  end

