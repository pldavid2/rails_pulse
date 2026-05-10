
# frozen_string_literal: true

module RailsPulse
  # Safely serializes local variables for exception tracking.
  # Handles circular references, large objects, and sensitive data.
  module VariableSerializer
    FILTERED_PATTERNS = %w[
      password
      passwd
      secret
      token
      api_key
      apikey
      access_key
      private_key
      credential
      auth
      bearer
      session
      cookie
    ].freeze

    MAX_STRING_LENGTH = 500
    MAX_ARRAY_LENGTH = 20
    MAX_HASH_SIZE = 30
    MAX_DEPTH = 4

    class << self
      def serialize(variables, filter_patterns: FILTERED_PATTERNS)
        return {} if variables.nil? || variables.empty?

        Thread.current[:rails_pulse_seen_objects] = Set.new

        variables.to_h do |name, value|
          serialized = if should_filter?(name, filter_patterns)
                         "[FILTERED]"
                       else
                         safe_serialize(value, 0, filter_patterns)
                       end
          [name.to_s, serialized]
        end
      rescue StandardError => e
        { "_serialization_error" => e.message }
      ensure
        Thread.current[:rails_pulse_seen_objects] = nil
      end

      private

      def safe_serialize(value, depth, filter_patterns)
        return "[MAX DEPTH]" if depth > MAX_DEPTH

        case value
        when nil
          nil
        when true, false
          value
        when Numeric
          value
        when Symbol
          value.to_s
        when String
          serialize_string(value)
        when Array
          serialize_array(value, depth, filter_patterns)
        when Hash
          serialize_hash(value, depth, filter_patterns)
        when Time, DateTime
          value.iso8601
        when Date
          value.to_s
        when Regexp
          value.inspect
        when Class, Module
          value.name
        when Proc, Method, UnboundMethod
          "#<#{value.class}>"
        when IO, File
          "#<#{value.class}:#{value.closed? ? 'closed' : 'open'}>"
        else
          serialize_object(value, depth, filter_patterns)
        end
      rescue StandardError => e
        "[Error: #{e.message}]"
      end

      def serialize_string(value)
        if value.encoding == Encoding::BINARY
          "[Binary data: #{value.bytesize} bytes]"
        elsif value.length > MAX_STRING_LENGTH
          "#{value[0, MAX_STRING_LENGTH]}... [truncated, #{value.length} chars total]"
        else
          value
        end
      end

      def serialize_array(value, depth, filter_patterns)
        return "[CIRCULAR]" if seen?(value)
        mark_seen(value)

        result = value.first(MAX_ARRAY_LENGTH).map do |item|
          safe_serialize(item, depth + 1, filter_patterns)
        end

        if value.length > MAX_ARRAY_LENGTH
          result << "[... #{value.length - MAX_ARRAY_LENGTH} more items]"
        end

        unmark_seen(value)
        result
      end

      def serialize_hash(value, depth, filter_patterns)
        return "[CIRCULAR]" if seen?(value)
        mark_seen(value)

        result = {}
        value.first(MAX_HASH_SIZE).each do |k, v|
          key = k.to_s
          result[key] = if should_filter?(key, filter_patterns)
                          "[FILTERED]"
                        else
                          safe_serialize(v, depth + 1, filter_patterns)
                        end
        end

        if value.size > MAX_HASH_SIZE
          result["_truncated"] = "#{value.size - MAX_HASH_SIZE} more keys"
        end

        unmark_seen(value)
        result
      end

      def serialize_object(value, depth, filter_patterns)
        return "[CIRCULAR]" if seen?(value)
        mark_seen(value)

        result = { "_class" => value.class.name }

        if value.respond_to?(:to_h) && !value.is_a?(Struct)
          begin
            hash_repr = value.to_h
            if hash_repr.is_a?(Hash) && hash_repr.size <= MAX_HASH_SIZE
              result["_data"] = serialize_hash(hash_repr, depth + 1, filter_patterns)
              unmark_seen(value)
              return result
            end
          rescue StandardError
            # Fall through to instance variables
          end
        end

        ivars = value.instance_variables.first(MAX_HASH_SIZE)
        if ivars.any?
          result["_ivars"] = {}
          ivars.each do |ivar|
            key = ivar.to_s.sub(/^@/, "")
            ivar_value = value.instance_variable_get(ivar)
            result["_ivars"][key] = if should_filter?(key, filter_patterns)
                                      "[FILTERED]"
                                    else
                                      safe_serialize(ivar_value, depth + 1, filter_patterns)
                                    end
          end
        end

        if value.instance_variables.size > MAX_HASH_SIZE
          result["_truncated"] = "#{value.instance_variables.size - MAX_HASH_SIZE} more ivars"
        end

        unmark_seen(value)
        result
      end

      def should_filter?(name, patterns)
        name_lower = name.to_s.downcase
        patterns.any? { |pattern| name_lower.include?(pattern.downcase) }
      end

      def seen?(object)
        Thread.current[:rails_pulse_seen_objects]&.include?(object.object_id)
      end

      def mark_seen(object)
        Thread.current[:rails_pulse_seen_objects]&.add(object.object_id)
      end

      def unmark_seen(object)
        Thread.current[:rails_pulse_seen_objects]&.delete(object.object_id)
      end
    end
  end
end
