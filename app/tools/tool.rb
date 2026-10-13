module Tool
  def self.all
    [
      Tool::Search,
      Tool::Feeds,
      Tool::Connect,
      Tool::Resources,
      Tool::Move
    ]
  end
end
