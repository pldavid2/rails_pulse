module RailsPulse
  module BacktraceHelper
    APP_FRAME_PATTERN = %r{/app/|/config/|/lib/}
    GEM_FRAME_PATTERN = %r{/gems/|/rubygems/|/bundler/|/ruby/}
    RUBY_KEYWORDS = Set.new(%w[
      def end class module do if else elsif unless case when return yield
      begin rescue ensure raise require include extend private protected
      public true false nil self super
    ]).freeze

    def app_frame?(frame)
      file = frame["file"].to_s
      file.match?(APP_FRAME_PATTERN) && !file.match?(GEM_FRAME_PATTERN)
    end

    # Strip everything before /app/, /lib/, /config/ so paths are relative.
    # Falls back to gem-name/rest for gem frames, or just basename for stdlib.
    def frame_display_path(frame)
      file = frame["file"].to_s
      # Gem frames: /…/gems/[ruby-ver]/gems/[gem-name]/lib/… → gem-name/lib/…
      if (match = file.match(%r{/gems/[^/]+/gems/([^/]+)/(.+)}))
        "#{match[1]}/#{match[2]}"
      # Bundler path gems: /…/gems/[gem-name]/lib/… → gem-name/lib/…
      elsif (match = file.match(%r{/gems/([^/]+)/(.+)}))
        "#{match[1]}/#{match[2]}"
      # App frames: strip absolute prefix, keep /app/…, /lib/…, /config/…
      elsif (match = file.match(%r{(/(?:app|lib|config)/.+)}))
        match[1]
      else
        File.basename(file)
      end
    end

    def frame_dirname(frame)
      File.dirname(frame_display_path(frame)) + "/"
    end

    def frame_basename(frame)
      File.basename(frame_display_path(frame))
    end

    def frame_source_lines(frame, radius: 3)
      file = frame["file"].to_s
      line = frame["line"].to_i
      return nil if file.blank? || line < 1
      return nil unless File.exist?(file) && File.file?(file)

      first_line = [ line - radius, 1 ].max
      last_line  = line + radius

      lines = {}
      File.foreach(file).with_index(1) do |content, lineno|
        break if lineno > last_line
        lines[lineno] = content.rstrip if lineno >= first_line
      end
      lines
    rescue Errno::EACCES, Errno::ENOENT
      nil
    end

    # Syntax highlighting using CSS classes (works in light and dark themes).
    # Single-pass scan to avoid regex corruption between passes.
    def format_source_line(code)
      escaped = html_escape(code).to_str
      result = +""
      i = 0

      while i < escaped.length
        if escaped[i] == "#" && escaped[i + 1] != "{"
          result << "<span class=\"backtrace-comment\">#{escaped[i..]}</span>"
          break
        elsif escaped[i] == "@"
          m = escaped[i..].match(/\A(@{1,2}[a-z_]\w*)/)
          if m
            result << "<span class=\"backtrace-ivar\">#{m[0]}</span>"
            i += m[0].length
          else
            result << escaped[i]
            i += 1
          end
        elsif escaped[i] == ":" && i > 0 && escaped[i - 1] != ":" && escaped[i + 1]&.match?(/[a-z_]/)
          m = escaped[i..].match(/\A(:[a-z_]\w*[!?]?)/)
          if m
            result << "<span class=\"backtrace-symbol\">#{m[0]}</span>"
            i += m[0].length
          else
            result << escaped[i]
            i += 1
          end
        elsif escaped[i, 6] == "&quot;" || escaped[i, 5] == "&#39;"
          delim = escaped[i, 6] == "&quot;" ? "&quot;" : "&#39;"
          end_pos = escaped.index(delim, i + delim.length)
          if end_pos
            chunk = escaped[i..end_pos + delim.length - 1]
            result << "<span class=\"backtrace-string\">#{chunk}</span>"
            i = end_pos + delim.length
          else
            result << escaped[i]
            i += 1
          end
        elsif escaped[i]&.match?(/[a-zA-Z_]/)
          m = escaped[i..].match(/\A([a-zA-Z_]\w*[!?]?)/)
          if m
            word = m[0]
            if RUBY_KEYWORDS.include?(word)
              result << "<span class=\"backtrace-keyword\">#{word}</span>"
            elsif word[0]&.match?(/[A-Z]/)
              result << "<span class=\"backtrace-constant\">#{word}</span>"
            else
              result << word
            end
            i += word.length
          else
            result << escaped[i]
            i += 1
          end
        else
          result << escaped[i]
          i += 1
        end
      end

      result.html_safe
    end
  end
end
