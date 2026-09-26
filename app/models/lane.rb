module Lane
  FIRST = 10

  class << self
    def priority(role)
      held = Resource.for_role(role)
      return FIRST if held.nil?

      FIRST + models.index(model(held, role)).to_i
    end

    def models
      named = Resource.capable_of(:inference).shared.order(:id).flat_map do |resource|
        next [] unless resource.respond_to?(:models)

        resource.models.values.map { |name| "#{resource.id}:#{name}" }
      end.uniq

      filing = agent_model
      filing && named.include?(filing) ? (named - [ filing ]) + [ filing ] : named
    end

    private

      def agent_model
        held = Resource.for_role(Resource::OpenaiCompatible::AGENT_ROLE)
        held && model(held, Resource::OpenaiCompatible::AGENT_ROLE)
      end

      def model(resource, role)
        "#{resource.id}:#{resource.model_for(role)}"
      rescue Resource::Unusable
        nil
      end
  end
end
