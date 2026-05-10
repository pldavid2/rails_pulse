module RailsPulse
  module Subscribers
    class ExceptionSubscriber
      def self.subscribe!
        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          new(event).process
        end
      end

      def initialize(event)
        @event = event
      end

      def process
        return unless RailsPulse.configuration.enabled
        return unless RailsPulse.configuration.track_exceptions
        return if RequestStore.store[:skip_recording_rails_pulse_activity]
        # Skip if middleware already captured this exception (avoids double tracking)
        exception = @event.payload[:exception_object]
        return unless exception

        RailsPulse::ExceptionCaptureService.capture(
          exception,
          request_url:     @event.payload[:path],
          request_method:  @event.payload[:method],
          request_params:  @event.payload[:params],
          environment:     Rails.env.to_s
        )
        # Flag so middleware doesn't double-track the same exception
        RequestStore.store[:rails_pulse_exception_tracked] = true
      rescue => e
        Rails.logger.error("[RailsPulse] ExceptionSubscriber error: #{e.message}")
      end
    end
  end
end
