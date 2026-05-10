# frozen_string_literal: true

module RailsPulse
  module Notifications
    class Base
      attr_reader :options

      def initialize(options = {})
        @options = options
      end

      def call(exception_group, exception_occurrence)
        raise NotImplementedError, "Subclasses must implement #call"
      end

      # Extension point for per-notifier filtering. Global rules (environment,
      # cooldown, threshold, first-occurrence) are evaluated by Tracker before
      # RailsPulse.notify is called, so this hook is for notifier-specific logic
      # only — e.g. a notifier that only fires for certain exception classes.
      # The base implementation allows all notifications through.
      def should_notify?(exception_group, exception_occurrence)
        true
      end

      protected

      def format_message(exception_group, exception_occurrence)
        {
          title: "Error in #{app_name}",
          exception_class: exception_group.exception_class,
          message: exception_group.message.to_s.truncate(200),
          occurrences: exception_group.occurrence_count,
          status: exception_group.status,
          location: format_location(exception_group),
          user: exception_occurrence.user_identifier,
          url: exception_occurrence.request_url,
          method: exception_occurrence.request_method,
          timestamp: exception_occurrence.created_at,
          reopened: exception_group.recently_reopened?
        }
      end

      def app_name
        RailsPulse.configuration.notifications[:app_name] || Rails.application.class.module_parent_name
      end

      def format_location(exception_group)
        exception_group.source_location || "unknown"
      end

      def status_emoji(exception_group)
        return "\u{1F504}" if exception_group.recently_reopened? # 🔄
        exception_group.occurrence_count == 1 ? "\u{1F6A8}" : "\u{26A0}\u{FE0F}" # 🚨 or ⚠️
      end
    end
  end
end
