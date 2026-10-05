require "test_helper"

class LonelyFacetsTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "lonely-#{SecureRandom.hex(4)}", name: "Lonely")
  end

  def item(key)
    Feed.create!(type: Feed::FILE, key: key, title: key)
  end

  def gone?(feed) = !Feed.exists?(feed.id)

  test "deleting the last item filed under a tag deletes the tag, and a tag still in use stays" do
    Tenant.switch(@tenant) do
      only, shared_by, other = item("gif"), item("one"), item("two")
      lonely, shared = Feed.tag!("bed scene"), Feed.tag!("bedroom")
      only.connect!(lonely)
      only.connect!(shared)
      other.connect!(shared)

      only.destroy!

      assert gone?(lonely)
      assert_not gone?(shared)
      assert_not gone?(shared_by)
    end
  end

  test "untagging the last item deletes the tag" do
    Tenant.switch(@tenant) do
      held = item("receipt")
      tag = Feed.tag!("hardware")
      held.connect!(tag)

      held.disconnect!(tag)

      assert gone?(tag)
      assert_not gone?(held)
    end
  end

  test "a tag reanalysis no longer gives an item is deleted when nothing else is filed under it" do
    Tenant.switch(@tenant) do
      held = item("photo")
      held.tag_with!([ "gradient background" ])
      old = Feed.tag_named("gradient background")

      held.tag_with!([ "sunset" ])

      assert gone?(old)
      assert_equal [ "sunset" ], held.tags.pluck(:key)
    end
  end

  test "a tag someone wrote a note on stays when it is left empty" do
    Tenant.switch(@tenant) do
      held = item("letter")
      tag = Feed.tag!("keep")
      tag.update!(note: "Things to keep for taxes.")
      held.connect!(tag)

      held.destroy!

      assert_not gone?(tag)
    end
  end

  test "a content type nothing has is deleted with its last item" do
    Tenant.switch(@tenant) do
      held = item("clip.gif")
      mime = Feed.mime!("image/gif")
      held.connect!(mime)

      held.destroy!

      assert gone?(mime)
    end
  end

  test "the daily sweep deletes tags and content types left empty some other way, in every tenant" do
    other = Tenant.create!(subdomain: "lonely-#{SecureRandom.hex(4)}", name: "Other")
    stray = Tenant.switch(@tenant) { Feed.tag!("stray") }
    elsewhere = Tenant.switch(other) { Feed.mime!("text/plain") }
    kept = Tenant.switch(@tenant) { Feed.tag!("in use").tap { |tag| item("note").connect!(tag) } }

    ForgetLonelyFacetsJob.perform_now

    Tenant.switch(@tenant) do
      assert gone?(stray)
      assert_not gone?(kept)
    end
    Tenant.switch(other) { assert gone?(elsewhere) }
  end
end
