# frozen_string_literal: true

module RailsPulse
  module Subscribers
    # Subscribes to Rails.error reporter API (Rails 7+) to capture
    # handled exceptions reported via Rails.error.handle/report.
    class RailsErrorSubscriber
      def report(error, handled:, severity:, context:, source: nil)
        return if should_ignore?(error)

        RailsPulse::ExceptionCaptureService.capture(error, environment: Rails.env.to_s, custom_context: context)
      end

      private

      def should_ignore?(error)
        RailsPulse.configuration.exception_tracking[:ignored_classes].include?(error.class.name)
      end
    end
  end
end
