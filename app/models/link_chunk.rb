class LinkChunk < ApplicationRecord
  include TenantScoped

  belongs_to :link_exchange
end
