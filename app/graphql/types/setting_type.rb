# frozen_string_literal: true

module Types
  class SettingType < Types::BaseObject
    field :key, String, null: false
    field :level, String, null: false
    field :value, String, null: false
    field :default_value, String, null: false
    field :allowed, [ String ], null: false
    field :label, String, null: false
    field :note, String, null: true
    field :unit, String, null: true,
                         description: "What its values count, such as px or %. Null for a plain choice."

    def level
      object[:level].to_s
    end

    def default_value
      object[:default]
    end
  end
end
