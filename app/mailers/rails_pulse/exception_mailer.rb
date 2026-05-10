# frozen_string_literal: true

module RailsPulse
  class ExceptionMailer < ::ActionMailer::Base
    include RailsPulse::Engine.routes.url_helpers

    layout false

    def exception_notification(exception_group:, exception_occurrence:, to:, from:)
      @exception_group = exception_group
      @occurrence = exception_occurrence
      @app_name = RailsPulse.configuration.notifications[:app_name] || Rails.application.class.module_parent_name
      @exception_group_url = exception_url(exception_group)
      @occurrence_url = exception_occurrence_url(exception_group, exception_occurrence)

      mail(to: to, from: from, subject: build_subject)
    end

    private

    def build_subject
      prefix = @exception_group.recently_reopened? ? "[REOPENED]" : "[EXCEPTION]"
      "#{prefix} #{@app_name}: #{@exception_group.exception_class}"
    end

    def default_url_options
      RailsPulse::Engine.config.action_mailer&.default_url_options ||
        ActionMailer::Base.default_url_options ||
        { host: "localhost" }
    end
  end
end