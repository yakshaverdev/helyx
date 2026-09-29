# One Credo run from the root covers plugins/bundled and the apps too; they
# have no config of their own.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "plugins/", "apps/", "credo/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      requires: ["credo/*.ex"],
      checks: %{
        extra: [
          # A test asserts order, not an upper bound of wall-clock time (#221).
          {Helyx.Credo.WallClockUpperBound, []}
        ],
        disabled: [
          # In Helyx.Core the alias for Helyx.Core.Plugins would expand inside
          # Module.concat(name, Plugins) and silently rename the registry.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
