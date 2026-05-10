# frozen_string_literal: true

require "net/http"
require "json"

module RailsPulse
  module Notifications
    class Resend < Base
      API_URL = "https://api.resend.com/emails"

      def initialize(api_key:, to:, from:)
        @api_key = api_key
        @to = Array(to)
        @from = from
      end

      def call(exception_group, exception_occurrence)
        uri = URI(API_URL)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"] = "application/json"
        request.body = build_payload(exception_group, exception_occurrence).to_json

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          Rails.logger.error "[RailsPulse] Resend API error: #{response.code} - #{response.body}"
        end

        response
      end

      private

      def build_payload(exception_group, occurrence)
        {
          from: @from,
          to: @to,
          subject: build_subject(exception_group),
          html: build_html(exception_group, occurrence)
        }
      end

      def build_subject(exception_group)
        prefix = exception_group.recently_reopened? ? "[REOPENED]" : "[ERROR]"
        "#{prefix} #{app_name}: #{exception_group.exception_class}"
      end

      def build_html(exception_group, occurrence)
        <<~HTML
          <!DOCTYPE html>
          <html>
          <head>
            <style>
              body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; font-size: 14px; line-height: 1.5; color: #1f2937; background-color: #f3f4f6; margin: 0; padding: 20px; }
              .container { max-width: 600px; margin: 0 auto; background-color: #ffffff; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow: hidden; }
              .header { background-color: #{exception_group.recently_reopened? ? '#d97706' : '#0891b2'}; color: #ffffff; padding: 20px; }
              .header h1 { margin: 0; font-size: 18px; }
              .content { padding: 20px; }
              .meta { margin: 15px 0; }
              .meta-row { padding: 8px 0; border-bottom: 1px solid #e5e7eb; display: flex; }
              .meta-label { color: #6b7280; width: 120px; flex-shrink: 0; }
              .meta-value { color: #1f2937; }
              .code { font-family: monospace; font-size: 13px; background-color: #f3f4f6; padding: 2px 6px; border-radius: 4px; }
              .backtrace { background-color: #1f2937; color: #e5e7eb; padding: 15px; border-radius: 6px; font-size: 12px; font-family: monospace; overflow-x: auto; white-space: pre-wrap; }
              .footer { padding: 15px 20px; background-color: #f9fafb; border-top: 1px solid #e5e7eb; font-size: 12px; color: #6b7280; }
              .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; background-color: #fef3c7; color: #92400e; margin-bottom: 10px; }
            </style>
          </head>
          <body>
            <div class="container">
              <div class="header">
                #{exception_group.recently_reopened? ? '<span class="badge">REOPENED</span>' : ''}
                <h1>#{escape_html(exception_group.exception_class)}</h1>
                <p style="margin: 5px 0 0 0; opacity: 0.9;">#{escape_html(app_name)}</p>
              </div>
              <div class="content">
                <p style="font-size: 16px; margin-top: 0;">#{escape_html(exception_group.message)}</p>
                <div class="meta">
                  <div class="meta-row">
                    <span class="meta-label">Occurrences</span>
                    <span class="meta-value"><strong>#{exception_group.occurrence_count}</strong></span>
                  </div>
                  <div class="meta-row">
                    <span class="meta-label">First seen</span>
                    <span class="meta-value">#{exception_group.first_seen_at&.strftime('%Y-%m-%d %H:%M:%S UTC')}</span>
                  </div>
                  <div class="meta-row">
                    <span class="meta-label">Last seen</span>
                    <span class="meta-value">#{exception_group.last_seen_at&.strftime('%Y-%m-%d %H:%M:%S UTC')}</span>
                  </div>
                  <div class="meta-row">
                    <span class="meta-label">Location</span>
                    <span class="meta-value"><span class="code">#{escape_html(exception_group.source_location || "unknown")}</span></span>
                  </div>
                  #{user_row(occurrence)}
                  #{request_row(occurrence)}
                </div>
                #{backtrace_section(occurrence)}
              </div>
              <div class="footer">
                Captured by RailsPulse at #{occurrence.created_at.strftime('%Y-%m-%d %H:%M:%S UTC')}
              </div>
            </div>
          </body>
          </html>
        HTML
      end

      def user_row(occurrence)
        return "" unless occurrence.user_identifier

        <<~HTML
          <div class="meta-row">
            <span class="meta-label">User</span>
            <span class="meta-value">#{escape_html(occurrence.user_identifier)}</span>
          </div>
        HTML
      end

      def request_row(occurrence)
        return "" unless occurrence.request_url.present?

        <<~HTML
          <div class="meta-row">
            <span class="meta-label">Request</span>
            <span class="meta-value">#{escape_html(occurrence.request_method)} #{escape_html(occurrence.request_url.truncate(60))}</span>
          </div>
        HTML
      end

      def backtrace_section(occurrence)
        lines = occurrence.app_backtrace_lines.first(8)
        return "" if lines.empty?

        formatted = lines.map { |l| escape_html(l.sub(Rails.root.to_s + "/", "")) }.join("\n")

        <<~HTML
          <h3 style="margin-bottom: 10px; font-size: 14px;">Stack Trace</h3>
          <div class="backtrace">#{formatted}</div>
        HTML
      end

      def escape_html(text)
        return "" if text.nil?

        text.to_s
            .gsub("&", "&amp;")
            .gsub("<", "&lt;")
            .gsub(">", "&gt;")
            .gsub('"', "&quot;")
      end
    end
  end
end
