module RailsPulse
  class ExceptionGroup < RailsPulse::ApplicationRecord
    self.table_name = "rails_pulse_exception_groups"

    has_many :occurrences, class_name: "RailsPulse::ExceptionOccurrence",
             foreign_key: :exception_group_id, dependent: :destroy

    validates :fingerprint, presence: true, uniqueness: true
    validates :exception_class, presence: true
    validates :first_seen_at, :last_seen_at, presence: true

    # Status lifecycle (added over upstream)
    scope :unresolved, -> { where(status: "unresolved") }
    scope :resolved, -> { where(status: "resolved") }
    scope :ignored, -> { where(status: "ignored") }
    scope :recent, -> { order(last_seen_at: :desc) }
    scope :by_class, ->(klass) { where(exception_class: klass) }
    scope :search, ->(query) {
      return all if query.blank?
      pattern = "%#{query.to_s.strip}%"
      where("exception_class LIKE :q OR message LIKE :q", q: pattern)
    }

    def self.ransackable_attributes(auth_object = nil)
      %w[id exception_class fingerprint first_seen_at last_seen_at occurrence_count status]
    end

    # Status actions
    def resolve!
      update!(status: "resolved", resolved_at: Time.current)
    end

    def unresolve!
      update!(status: "unresolved", resolved_at: nil)
    end

    def ignore!
      update!(status: "ignored")
    end

    def recently_reopened?
      resolved_at.present? && last_seen_at.present? && last_seen_at > resolved_at
    end

    def to_s
      exception_class
    end
  end
end
