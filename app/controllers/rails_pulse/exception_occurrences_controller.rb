module RailsPulse
  class ExceptionOccurrencesController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound do
      redirect_to exceptions_path, alert: "Exception occurrence not found."
    end

    before_action :set_exception_group
    before_action :set_occurrence

    def show
      @source_context = @occurrence.source_context
      @local_variables = @occurrence.parsed_local_variables
      @custom_context = @occurrence.parsed_custom_context
    end

    private

    def set_exception_group
      @exception_group = ExceptionGroup.find(params[:exception_id])
    end

    def set_occurrence
      @occurrence = @exception_group.occurrences.find(params[:id])
    end
  end
end
