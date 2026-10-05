class SummarizeUnsummarizedJob < ApplicationJob
  queue_as :analysis

  def perform
    Feed.unsummarized.find_each { |feed| feed.analyze!(cause: "sync") }
  end
end
