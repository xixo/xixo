require "test_helper"

class ResourceDeclaringTest < ActiveSupport::TestCase
  setup do
    @tenant = Tenant.create!(subdomain: "decl-#{SecureRandom.hex(4)}", name: "Declared")
    @root = Pathname.new(Dir.mktmpdir)

    ENV["XIXO_FILESYSTEM_ROOTS"] = @root.to_s
  end

  teardown do
    ENV.delete("XIXO_FILESYSTEM_ROOTS")
    FileUtils.remove_entry(@root) if @root.exist?
  end

  def declaring(**overrides)
    {
      "files" => {
        "type" => "filesystem",
        "name" => "Files",
        "default_storage" => true,
        "settings" => { "root" => @root.to_s }
      }.merge(overrides)
    }
  end

  test "a declaration becomes a resource, named and defaulted as it says" do
    Tenant.switch(@tenant) do
      held = Resource.declare!(declaring)

      assert_equal 1, held.length

      files = Resource.find_by!(key: "files")

      assert_equal "filesystem", files.class.sti_name
      assert_equal "Files", files.name
      assert_equal @root.to_s, files.details["root"]
      assert files.default_storage?
    end
  end

  test "declaring twice is one resource, brought back into step" do
    Tenant.switch(@tenant) do
      Resource.declare!(declaring)
      Resource.find_by!(key: "files").update!(name: "Renamed by hand")

      assert_no_difference -> { Resource.count } do
        Resource.declare!(declaring)
      end

      assert_equal "Files", Resource.find_by!(key: "files").name
    end
  end

  test "only what the type declares is read, so a stray key never lands" do
    Tenant.switch(@tenant) do
      Resource.declare!(declaring("settings" => { "root" => @root.to_s, "sudo" => "yes" }))

      files = Resource.find_by!(key: "files")

      assert_equal [ "root" ], files.details.keys
      assert_empty files.credentials
    end
  end

  test "a declaration missing a required field is refused rather than half-applied" do
    Tenant.switch(@tenant) do
      assert_raises Resource::Settings::Missing do
        Resource.declare!(declaring("settings" => {}))
      end

      assert_equal 0, Resource.count
    end
  end

  test "a type nobody attaches by hand cannot be declared either" do
    Tenant.switch(@tenant) do
      assert_raises Resource::Settings::Unattachable do
        Resource.declare!("blobs" => { "type" => "database" })
      end
    end
  end

  test "a declaration reaches every tenant, one at a time" do
    other = Tenant.create!(subdomain: "decl-#{SecureRandom.hex(4)}", name: "Elsewhere")

    [ @tenant, other ].each { |held| Tenant.switch(held) { Resource.declare!(declaring) } }

    [ @tenant, other ].each do |held|
      Tenant.switch(held) { assert_equal [ "files" ], Resource.pluck(:key) }
    end
  end

  test "the shipped file names a filesystem resource, and the test environment none" do
    held = YAML.safe_load(ERB.new(Resource::DECLARATIONS.read).result, aliases: true)

    assert_equal "filesystem", held.dig("production", "files", "type")
    assert_equal held["production"], held["development"], "one shipped stack, one declaration"
    assert_empty held["test"], "a suite declares what it needs in the test that needs it"
  end
end
