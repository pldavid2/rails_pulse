# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module RailsPulse
  module Notifications
    class Webhook < Base
      def initialize(url:, method: :post, headers: {}, **options)
        super(options)
        @url = url
        @method = method.to_sym
        @headers = headers
      end

      def call(exception_group, exception_occurrence)
        payload = format_webhook_payload(exception_group, exception_occurrence)
        send_request(payload)
      end

      private

      def format_webhook_payload(exception_group, exception_occurrence)
        {
          event: "error.occurred",
          timestamp: Time.current.iso8601,
          app: RailsPulse.configuration.notifications[:app_name] || Rails.application.class.module_parent_name,
          environment: Rails.env,
          exception_group: {
            id: exception_group.id,
            fingerprint: exception_group.fingerprint,
            exception_class: exception_group.exception_class,
            message: exception_group.message,
            status: exception_group.status,
            occurrence_count: exception_group.occurrence_count,
            first_seen_at: exception_group.first_seen_at&.iso8601,
            last_seen_at: exception_group.last_seen_at&.iso8601,
            source_location: exception_group.source_location,
            recently_reopened: exception_group.recently_reopened?
          },
          occurrence: {
            id: exception_occurrence.id,
            message: exception_occurrence.message.to_s.truncate(500),
            request_url: exception_occurrence.request_url,
            request_method: exception_occurrence.request_method,
            user_id: exception_occurrence.user_id,
            user_identifier: exception_occurrence.user_identifier,
            ip_address: exception_occurrence.ip_address,
            created_at: exception_occurrence.created_at.iso8601
          }
        }
      end

      def send_request(payload)
        uri = URI(@url)

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10

        request = case @method
                  when :post then Net::HTTP::Post.new(uri)
                  when :put then Net::HTTP::Put.new(uri)
                  else raise ArgumentError, "Unsupported HTTP method: #{@method}"
                  end

        request["Content-Type"] = "application/json"
        @headers.each { |k, v| request[k.to_s] = v }
        request.body = payload.to_json

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error "[RailsPulse::Webhook] Request failed: #{response.code} #{response.body.to_s.truncate(200)}"
        end
      rescue => e
        Rails.logger.error "[RailsPulse::Webhook] Failed to send: #{e.message}"
      end
    end
  end
end
