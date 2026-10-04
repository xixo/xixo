module Analyzer
  class Conversation < Base
    SAYS = <<~SAYS.strip.freeze
      two or three sentences saying what was asked and what was found, across every question.
          Name the entities you listed rather than their category. Say only what is above.
    SAYS

    def self.handles?(_feed)
      false
    end

    def self.summary_role
      Resource::OpenaiCompatible::AGENT_ROLE
    end

    def summary_effort
      inference&.ask_effort
    end

    def roll_up!
      step(:conversation, force: true) { transcript }
      attempt { summarize! }
      feed.reload.announce_analyzed!
    end

    def transcript
      feed.conversation(through: analysis).filter_map do |turn|
        next if turn.said.blank?

        "Asked: #{turn.question}\nAnswered: #{turn.said}"
      end.join("\n\n").truncate(MAX_TEXT)
    end

    def summary_noun
      "conversation"
    end

    def summary_says
      SAYS
    end

    def file_facts
      "Type: a conversation of #{feed.conversation(through: analysis).size} questions, kept as a note"
    end

    def summary_body
      fenced(step_result(:conversation).to_s.strip)
    end
  end
end
