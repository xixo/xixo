# frozen_string_literal: true

module Mutations
  class LinkMachine < BaseMutation
    description "Starts linking a machine that installs xixo link itself. Names a new machine, or takes " \
                "an existing one to link it again, and answers with a code the machine enrolls with once."

    argument :key, String, required: false, description: "A name for a new machine."
    argument :name, String, required: false
    argument :id, ID, required: false, description: "A machine already attached, for a fresh code."

    field :resource, Types::ResourceType, null: false
    field :code, String, null: false,
          description: "The single-use code the machine enrolls and links up with. It is shown only here."
    field :expires_at, GraphQL::Types::ISO8601DateTime, null: false,
          description: "When the code stops working, about ten minutes from now."

    def resolve(key: nil, name: nil, id: nil)
      context[:grant].administer!("links a machine")
      machine = id.present? ? existing(id) : created(key, name)
      machine.operated_by!(context[:grant])
      code = Resource::Machine::Linking.start!(machine)

      noted(machine, fresh: id.present?)

      { resource: machine, code: code.token, expires_at: code.expires_at }
    rescue Grant::Denied, Resource::Refused, Resource::Failed => e
      refused(e.message)
    end

    private

      def existing(id)
        machine = Resource::Machine.visible_to(context[:grant]).find_by(id: id) || refused("no machine with id #{id}")
        refused("xixo link beside the server links itself") if machine.local?
        machine
      end

      def created(key, name)
        named = key.to_s.strip
        refused("a machine needs a name") if named.empty?

        machine = Resource::Machine.new(key: named, name: name.to_s.strip.presence || named, details: { "folders" => [] })
        refused(machine.errors.full_messages.to_sentence) unless machine.save
        machine
      end

      def noted(machine, fresh:)
        AuditEvent.record(
          channel: "graphql", action: "link_machine", status: "ok",
          grant: context[:grant], context: Current.audit,
          told: fresh ? "asked for a fresh code to link #{machine.key}" : "started linking #{machine.key}",
          arguments: { "key" => machine.key }
        )
      end
  end
end
