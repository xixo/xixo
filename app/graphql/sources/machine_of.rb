# frozen_string_literal: true

module Sources
  class MachineOf < GraphQL::Dataloader::Source
    def fetch(resources)
      held = Resource::Machine.holding(resources)

      resources.map { |resource| held[resource.id]&.id }
    end
  end
end
