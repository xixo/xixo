# frozen_string_literal: true

module Types
  class MachineGpuType < Types::BaseObject
    grants "xixo:resources:read"

    field :maker, String, null: false, hash_key: "maker", description: "NVIDIA, AMD, Intel, or Apple."
    field :model, String, null: false, hash_key: "model", description: "The model, such as NVIDIA GeForce GTX 1070. Empty when the machine cannot tell."
    field :memory, GraphQL::Types::BigInt, null: false, hash_key: "memory",
          description: "Its memory in bytes. For an Apple chip, the machine's memory, which the GPU shares. Zero when unknown."
    field :driver, String, null: false, hash_key: "driver",
          description: "The driver version, such as 580.178.04, \"nouveau\" for the open NVIDIA driver, \"built in\" on an " \
                       "Apple chip, or empty when no driver is loaded."
  end
end
