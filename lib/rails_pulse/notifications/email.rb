# frozen_string_literal: true

module RailsPulse
  module Notifications
    class Email < Base
      def initialize(to:, from: nil)
        @to = Array(to)
        @from = from
      end

      def call(exception_group, exception_occurrence)
        from_address = @from || default_from_address

        RailsPulse::ExceptionMailer.exception_notification(
          exception_group: exception_group,
          exception_occurrence: exception_occurrence,
          to: @to,
          from: from_address
        ).deliver_later
      rescue => e
        Rails.logger.error "[RailsPulse] Email notification failed: #{e.message}"
        raise unless Rails.env.production?
      end

      private

      def default_from_address
        ActionMailer::Base.default[:from] || "errors@#{default_host}"
      end

      def default_host
        ActionMailer::Base.default_url_options[:host] || "localhost"
      end
    end
  end
end
