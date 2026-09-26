module Lane
  FIRST = 10

  class << self
    def priority(role)
      held = Resource.for_role(role)
      return FIRST if held.nil?

      FIRST + models.index(model(held, role)).to_i
    end

    def models
      Resource.capable_of(:inference).shared.order(:id).flat_map do |resource|
        next [] unless resource.respond_to?(:models)

        resource.models.values.map { |name| "#{resource.id}:#{name}" }
      end.uniq
    end

    private

      def model(resource, role)
        "#{resource.id}:#{resource.model_for(role)}"
      rescue Resource::Unusable
        nil
      end
  end
end
