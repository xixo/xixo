require "test_helper"

class ChildrenTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    SearchIndex.reset!

    @tenant = Tenant.create!(subdomain: "kids-#{SecureRandom.hex(4)}", name: "Children")

    Tenant.switch(@tenant) do
      @mail = Resource::Database.create!(key: "mailbox")
      @mail.upload("march.eml", eml)
      @feed = Feed.create!(type: Feed::FILE, key: "march.eml", title: "March invoice")
      Reference.record!(feed: @feed, resource: @mail,
                             locator_key: "march.eml", locator: { "key" => "march.eml" })
    end
  end

  def eml(attachment: "invoice.txt", body: "the numbers are in the attachment")
    mail = Mail.new do
      from "ash@example.invalid"
      to "bea@example.invalid"
      subject "March invoice"

      text_part { body "Please see attached." }
    end

    mail.attachments[attachment] = { mime_type: "text/plain", content: body }
    mail.to_s
  end

  def analyze!(feed = nil)
    held = feed || @feed
    Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, held.id) }
  end

  def children
    Tenant.switch(@tenant) { @feed.reload.children.to_a }
  end

  test "an attachment is catalogued as an item of its own, under the message" do
    analyze!

    held = children

    assert_equal 1, held.length

    Tenant.switch(@tenant) do
      child = held.first

      assert_equal "invoice.txt", child.title
      assert_equal "text/plain", child.mime
      assert_equal @feed.id, child.parent_id
      assert_equal "the numbers are in the attachment", child.reference.download.read
    end
  end

  test "the message is not analyzed until its children are" do
    analyze!

    Tenant.switch(@tenant) do
      assert_nil @feed.reload.analyzed_at, "a message with unread attachments is not read yet"
      assert_not @feed.children_ready?
    end
  end

  test "reading the children lets the message through, and its body includes theirs" do
    analyze!

    children.each { |child| analyze!(child) }

    analyze!

    Tenant.switch(@tenant) do
      held = @feed.reload

      assert held.analyzed_at.present?
      assert held.children_ready?
      assert_includes held.readable_text, "the numbers are in the attachment"
      assert_includes held.readable_text, "Please see attached"
    end
  end

  test "the last child to finish is what wakes the message" do
    analyze!

    child = children.first

    perform_enqueued_jobs(only: AnalyzeFeedJob) do
      Tenant.switch(@tenant) { AnalyzeFeedJob.perform_now(@tenant.id, child.id) }
    end

    Tenant.switch(@tenant) { assert @feed.reload.analyzed_at.present? }
  end

  test "extraction is idempotent, so re-analysis finds its children rather than copying them" do
    analyze!
    analyze!
    analyze!

    assert_equal 1, children.length
  end

  test "re-analysis does not write the attachment's bytes again" do
    analyze!

    written = 0
    Resource::Database.class_eval do
      alias_method :upload_without_count, :upload
      define_method(:upload) { |name, body| written += 1; upload_without_count(name, body) }
    end

    begin
      analyze!
      analyze!
    ensure
      Resource::Database.class_eval do
        remove_method :upload
        alias_method :upload, :upload_without_count
        remove_method :upload_without_count
      end
    end

    assert_equal 0, written, "the bytes were already there; a re-read must not rewrite them"
  end

  test "an analyzer that declares no children extracts none" do
    Tenant.switch(@tenant) do
      @mail.upload("plain.txt", "nothing inside this")
      plain = Feed.create!(type: Feed::FILE, key: "plain.txt", title: "plain.txt")
      Reference.record!(feed: plain, resource: @mail,
                             locator_key: "plain.txt", locator: { "key" => "plain.txt" })

      analyze!(plain)

      assert_empty plain.reload.children
      assert plain.analyzed_at.present?, "nothing to wait for means nothing waits"
    end
  end

  test "a message whose attachment is unreadable still reads itself" do
    Tenant.switch(@tenant) do
      @mail.upload("broken.eml", "this is not a message")
      broken = Feed.create!(type: Feed::FILE, key: "broken.eml", title: "broken")
      Reference.record!(feed: broken, resource: @mail,
                             locator_key: "broken.eml", locator: { "key" => "broken.eml" })

      analyze!(broken)

      assert_empty broken.reload.children
      assert broken.analyzed_at.present?
    end
  end

  test "a child is searchable in its own right, and so is its parent by its contents" do
    analyze!
    children.each { |child| analyze!(child) }
    analyze!

    SearchIndex.refresh!

    Tenant.switch(@tenant) do
      found = Feed.search("numbers").to_a

      assert_includes found.map(&:id), @feed.id
    end
  end

  test "nesting stops at a depth rather than following a message into itself" do
    Tenant.switch(@tenant) do
      deep = @feed
      Feed::DEPTH.times { deep = Feed.create!(type: Feed::FILE, key: "nested", title: "nested", parent: deep) }

      assert_equal Feed::DEPTH, deep.depth
    end
  end
end
