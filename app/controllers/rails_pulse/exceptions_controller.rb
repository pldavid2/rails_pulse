module RailsPulse
  class ExceptionsController < ApplicationController
    include TimeRangeConcern

    rescue_from ActiveRecord::RecordNotFound do
      redirect_to exceptions_path, alert: "Exception group not found (may have been deleted)."
    end

    before_action :set_exception_group, only: [:show, :resolve, :unresolve, :ignore, :destroy]

    def index
      @start_time, @end_time, @selected_time_range = setup_time_range

      ransack_params = (params[:q] || {}).dup
      ransack_params[:last_seen_at_gteq] = Time.zone.at(@start_time)
      ransack_params[:last_seen_at_lteq] = Time.zone.at(@end_time)

      # Status filter (not part of Ransack)
      base_scope = ExceptionGroup.all
      base_scope = base_scope.where(status: params[:status]) if params[:status].present?

      @ransack_query = base_scope.ransack(ransack_params)
      @ransack_query.sorts = "last_seen_at desc" if @ransack_query.sorts.empty?
      @pagination, @table_data = paginate(@ransack_query.result, limit: session_pagination_limit)

      # Chart: occurrences over time
      chart_scope = ExceptionOccurrence.where(occurred_at: Time.zone.at(@start_time)..Time.zone.at(@end_time))
      @chart_data = chart_scope
        .group(Arel.sql("DATE(occurred_at)"))
        .order(Arel.sql("DATE(occurred_at)"))
        .count
    end

    def show
      occurrences = @exception_group.occurrences.order(occurred_at: :desc)
      @pagination, @occurrences = paginate(occurrences, limit: session_pagination_limit)

      # Chart: this group's occurrences over time
      @chart_data = @exception_group.occurrences
        .group(Arel.sql("DATE(occurred_at)"))
        .order(Arel.sql("DATE(occurred_at)"))
        .count
    end

    def resolve
      @exception_group.resolve!
      redirect_to exception_path(@exception_group), notice: "Exception group resolved."
    end

    def unresolve
      @exception_group.unresolve!
      redirect_to exception_path(@exception_group), notice: "Exception group reopened."
    end

    def ignore
      @exception_group.ignore!
      redirect_to exception_path(@exception_group), notice: "Exception group ignored."
    end

    def destroy
      @exception_group.destroy!
      redirect_to exceptions_path, notice: "Exception group deleted."
    end

    private

    def set_exception_group
      @exception_group = ExceptionGroup.find(params[:id])
    end
  end
end
