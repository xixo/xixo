class AgentChunk < ApplicationRecord
  include TenantScoped

  belongs_to :agent_exchange
end
