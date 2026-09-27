require "test_helper"

class SettingTest < ActiveSupport::TestCase
  setup do
    @demo = Tenant.create!(subdomain: "demo-#{SecureRandom.hex(4)}", name: "Demo items")
    @acme = Tenant.create!(subdomain: "acme-#{SecureRandom.hex(4)}", name: "Acme")
  end

  test "a setting nobody has touched reads as its default" do
    Tenant.switch(@demo) do
      assert_equal "list", Setting.read("catalog_view", subject: "ada")
    end
  end

  test "what was written is what is read back" do
    Tenant.switch(@demo) do
      Setting.write!("catalog_view", "cards", subject: "ada")

      assert_equal "cards", Setting.read("catalog_view", subject: "ada")
    end
  end

  test "writing twice moves the same row rather than adding one" do
    Tenant.switch(@demo) do
      Setting.write!("catalog_view", "cards", subject: "ada")
      Setting.write!("catalog_view", "list", subject: "ada")

      assert_equal 1, Setting.where(key: "catalog_view", subject: "ada").count
      assert_equal "list", Setting.read("catalog_view", subject: "ada")
    end
  end

  test "a personal setting is one person's and not another's" do
    Tenant.switch(@demo) do
      Setting.write!("catalog_view", "cards", subject: "ada")

      assert_equal "cards", Setting.read("catalog_view", subject: "ada")
      assert_equal "list", Setting.read("catalog_view", subject: "someone-else")
    end
  end

  test "the same subject in another tenant reads their own setting" do
    Tenant.switch(@demo) { Setting.write!("catalog_view", "cards", subject: "ada") }

    Tenant.switch(@acme) do
      assert_equal "list", Setting.read("catalog_view", subject: "ada")
    end
  end

  test "row-level security holds when the application scope is gone" do
    Tenant.switch(@demo) { Setting.write!("catalog_view", "cards", subject: "ada") }

    Tenant.switch(@acme) do
      assert_empty Setting.unscoped.where(key: "catalog_view").pluck(:value)
    end
  end

  test "a value the definition does not allow is refused" do
    Tenant.switch(@demo) do
      assert_raises ActiveRecord::RecordInvalid do
        Setting.write!("catalog_view", "carousel", subject: "ada")
      end
    end
  end

  test "a key with no definition is refused" do
    Tenant.switch(@demo) do
      assert_raises Setting::Unknown do
        Setting.write!("nonsense", "cards", subject: "ada")
      end

      assert_raises Setting::Unknown do
        Setting.read("nonsense", subject: "ada")
      end
    end
  end

  test "a personal definition names the scopes that reach it" do
    definition = Setting.definition!("catalog_view")

    assert_predicate definition, :personal?
    assert_equal "uris:settings:read", definition.reads
    assert_equal "uris:settings:write", definition.writes
    assert_includes Grant::SCOPES, definition.reads
    assert_includes Grant::SCOPES, definition.writes
  end

  test "a shared setting is one value for everyone in the tenant" do
    Tenant.switch(@demo) do
      Setting.write!("hires_size", "2048", subject: "ada")

      assert_equal "2048", Setting.read("hires_size", subject: "bea")
      assert_equal 1, Setting.where(key: "hires_size").count
      assert_nil Setting.find_by(key: "hires_size").subject
    end

    Tenant.switch(@acme) do
      assert_equal "1500", Setting.read("hires_size", subject: "ada")
    end
  end

  test "a shared definition is reached with the same scopes as a personal one" do
    definition = Setting.definition!("thumbnail_size")

    assert_not_predicate definition, :personal?
    assert_equal "uris:settings:read", definition.reads
    assert_equal "uris:settings:write", definition.writes
  end
end
