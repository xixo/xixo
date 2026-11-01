# frozen_string_literal: true

module Mutations
  class RequestMachineUpdate < BaseMutation
    description "Steers how xixo link on the machines updates. With a machine: update_now offers it the release at once, " \
                "ahead of the rollout; pause and resume turn its updates off and on; first makes it the machine that " \
                "updates first on its platform; roll_back tells it to go back to the release before, which it still " \
                "holds. Without a machine, pause and resume stop and continue the rollout for every machine."

    argument :id, ID, required: false, description: "The machine. Left off, the action is about the rollout."
    argument :action, String, required: true, description: "update_now, pause, resume, first, or roll_back."

    field :link_updates, Types::LinkUpdatesType, null: false

    def resolve(action:, id: nil)
      context[:grant].administer!("steers updates of xixo link")
      machine = id.nil? ? nil : Resource::Machine.visible_to(context[:grant]).find_by(id: id) || refused("no machine with id #{id}")

      told = machine ? on_machine(machine, action) : on_rollout(action)
      AuditEvent.record(
        channel: "graphql", action: "request_machine_update", status: "ok", grant: context[:grant], context: Current.audit,
        told: told, arguments: { "key" => machine&.key, "action" => action }.compact
      )

      { link_updates: {} }
    rescue Grant::Denied, LinkRollout::Refused, Resource::Refused => e
      refused(e.message)
    end

    private

      def on_machine(machine, action)
        case action
        when "pause"
          machine.set_updates!(false)
          "paused updates of xixo link on #{machine.key}"
        when "resume"
          machine.set_updates!(true)
          "resumed updates of xixo link on #{machine.key}"
        when "first" then first(machine)
        when "update_now" then offered(machine)
        when "roll_back" then rolled_back(machine)
        else refused("#{action.inspect} is not something xixo does with a machine's updates")
        end
      end

      def first(machine)
        rollout = LinkRollout.current! || refused("this xixo ships no release description, so there is no rollout")
        rollout.first!(machine)
        "chose #{machine.key} to update first"
      end

      def offered(machine)
        refused("#{machine.key} cannot update now: #{machine.update_state}") unless machine.wants_update? && machine.connected?

        machine.offer_update!(staged: false) || refused("#{machine.key} has nothing to update to")
        "offered #{machine.key} the release at once"
      end

      def rolled_back(machine)
        to = machine.release_before || refused("#{machine.key} holds no release before the one it runs")
        refused("#{machine.key} is not connected") unless machine.connected?

        machine.offer_roll_back!(to)
        "asked #{machine.key} to go back to xixo link #{to['version']}"
      end

      def on_rollout(action)
        LinkRollout.request!(action)
        action == "pause" ? "paused the rollout of xixo link to every machine" : "resumed the rollout of xixo link"
      end
  end
end
