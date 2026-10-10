class Current < ActiveSupport::CurrentAttributes
  attribute :tenant, :grant, :audit, :origin, :acting_for, :confined_to, :kept_for, :analysis

  def audit
    attributes[:audit] || {}
  end
end
