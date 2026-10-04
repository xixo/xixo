class Resource
  class Feedback < Resource
    SHELF = "/feedback".freeze
    REVIEWED_EVERY = 1.week
    REVIEW_TURNS = 16

    REVIEW = <<~TEXT.freeze
      Everything connected to feed #{SHELF} is something an agent or a person asked for and nothing
      here could give: a question no tool answered, or a thing no tool could do. Read the notes
      connected to it with feed, leaving out the reviews titled "Feedback review". Group what was
      wanted by what would provide it, such as a resource to attach, a kind of file to sync, or a
      change to uris itself, and count how often each came up. Then make one note titled "Feedback
      review" and the date, listing each group with its count, two or three of the questions in it,
      and the change you propose, most asked first. Connect that note to feed #{SHELF}.
    TEXT
    QUESTION = 500
    CONTEXT = 4_000

    SAID = "Nothing here can answer that yet. It was kept as feedback, so whoever builds this " \
           "sees what was wanted. Carry on with what you have.".freeze

    serves :feedback

    def self.attaching
      {
        label: "Feedback",
        blurb: "Takes any question no tool here can answer, answers none of them, and keeps each as a note " \
               "in the #{SHELF} feed: what was asked, what it was for, and what would have helped. That " \
               "feed reviews them every week and proposes what to change.",
        names: "A name for it",
        fields: []
      }
    end

    def self.command_schema
      { ask: { question: "string", context: "string?", wanted: "string?" } }
    end

    after_create_commit :shelf

    def check!
      shelf
      true
    end

    def shelf
      Feed.address(SHELF) || Feed.create!(type: Feed::ADDRESS, key: SHELF, title: "Feedback").tap do |held|
        held.create_schedule!(prompt: REVIEW, interval: REVIEWED_EVERY.to_i, turns: REVIEW_TURNS)
      end
    end

    def command_ask(question:, context: nil, wanted: nil)
      asked = question.to_s.squish.truncate(QUESTION)
      raise ArgumentError, "ask needs a question" if asked.blank?

      kept = kept!(asked, context, wanted)
      { answered: false, said: SAID, feedback: kept.id.to_s }
    end

    def kept!(question, context, wanted)
      Feed.create!(type: Feed::NOTE, key: "feedback: #{question}", title: "Wanted: #{question.truncate(80)}",
                   note: written(question, context, wanted)).tap do |held|
        held.connect!(shelf)
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
