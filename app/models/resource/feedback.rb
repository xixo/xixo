class Resource
  class Feedback < Resource
    TAG = "feedback".freeze
    QUESTION = 500
    CONTEXT = 4_000

    SAID = "Nothing here can answer that yet. It was kept as feedback, so whoever builds this " \
           "sees what was wanted. Carry on with what you have.".freeze

    serves :feedback

    def self.attaching
      {
        label: "Feedback",
        blurb: "Takes any question no tool here can answer, answers none of them, and keeps each as a note " \
               "under the feedback tag: what was asked, what it was for, and what would have helped. Read " \
               "the tag to see what agents and people needed.",
        names: "A name for it",
        fields: []
      }
    end

    def self.command_schema
      { ask: { question: "string", context: "string?", wanted: "string?" } }
    end

    def check!
      true
    end

    def command_ask(question:, context: nil, wanted: nil)
      asked = question.to_s.squish.truncate(QUESTION)
      raise ArgumentError, "ask needs a question" if asked.blank?

      kept = kept!(asked, context, wanted)
      { answered: false, said: SAID, feedback: kept.id.to_s }
    end

    def kept!(question, context, wanted)
      Feed.create!(type: Feed::NOTE, key: "#{TAG}: #{question}", title: "Wanted: #{question.truncate(80)}",
                   note: written(question, context, wanted)).tap do |held|
        held.connect!(Feed.tag!(TAG))
        held.connect!(Feed.find(Current.acting_for)) if Current.acting_for && Feed.exists?(Current.acting_for)
      end
    end

    private

      def written(question, context, wanted)
        [
          "Asked: #{question}",
          ("For: #{context.to_s.squish.truncate(CONTEXT)}" if context.present?),
          ("Would have helped: #{wanted.to_s.squish.truncate(CONTEXT)}" if wanted.present?),
          ("By: #{Current.grant.subject}" if Current.grant),
          ("While working on feed #{Current.acting_for}" if Current.acting_for),
          "Through: #{key}"
        ].compact.join("\n")
      end
  end
end
