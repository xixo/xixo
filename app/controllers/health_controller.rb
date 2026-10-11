class HealthController < ActionController::Base
  def show
    checks = Health.checks
    serving = checks[:database] && checks[:search]

    render json: { status: word(serving), checks: checks.transform_values { |ok| word(ok) } },
           status: serving ? :ok : :service_unavailable
  end

  private

    def word(ok)
      ok ? "ok" : "failing"
    end
end
