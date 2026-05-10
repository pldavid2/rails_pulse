module RailsPulse
  class ExceptionOccurrence < RailsPulse::ApplicationRecord
    self.table_name = "rails_pulse_exception_occurrences"

    belongs_to :exception_group, class_name: "RailsPulse::ExceptionGroup"

    serialize :backtrace, type: Array, coder: JSON
    serialize :request_params, type: Hash, coder: JSON

    validates :exception_class, presence: true
    validates :occurred_at, presence: true

    scope :recent, -> { order(occurred_at: :desc) }

    def self.ransackable_attributes(auth_object = nil)
      %w[id exception_class message occurred_at request_url environment]
    end

    # Enhanced: local variables (JSON text from TracePoint capture)
    def parsed_local_variables
      return {} if local_variables.blank?
      return local_variables if local_variables.is_a?(Hash)
      JSON.parse(local_variables)
    rescue
      {}
    end

    # Enhanced: custom context (JSON text)
    def parsed_custom_context
      return {} if custom_context.blank?
      return custom_context if custom_context.is_a?(Hash)
      JSON.parse(custom_context)
    rescue
      {}
    end

    # Enhanced: user identification
    def user
      return nil unless user_id && user_type
      user_class = user_type.safe_constantize
      return nil unless user_class
      user_class.find_by(id: user_id)
    rescue
      nil
    end

    def user_identifier
      return nil unless user_id
      cached_user = user
      return "#{user_type}##{user_id}" unless cached_user
      [:email, :name, :username, :id].each do |method|
        return cached_user.public_send(method).to_s if cached_user.respond_to?(method)
      end
      "#{user_type}##{user_id}"
    rescue
      "User##{user_id}"
    end

    # Enhanced: source context (reads file around error line)
    def source_context(context_lines: 7)
      app_frame = backtrace&.find { |f| f["file"].to_s.match?(%r{/app/}) && !f["file"].to_s.match?(%r{/gems/}) }
      return nil unless app_frame

      file_path = app_frame["file"]
      line_number = app_frame["line"].to_i
      return nil unless file_path && line_number > 0 && File.exist?(file_path)

      lines = File.readlines(file_path)
      start_line = [line_number - context_lines, 1].max
      end_line = [line_number + context_lines, lines.length].min

      {
        file_path: file_path.sub(Rails.root.to_s + "/", ""),
        line_number: line_number,
        start_line: start_line,
        lines: (start_line..end_line).map { |n| { number: n, code: lines[n - 1]&.chomp || "", current: n == line_number } }
      }
    rescue
      nil
    end

    def to_s
      "#{exception_class} ##{id}"
    end
  end
end
