# One Credo run from the root covers plugins/bundled and the apps too; they
# have no config of their own.
%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "plugins/", "apps/", "credo/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/tmp/"]
      },
      requires: ["credo/*.ex"],
      checks: %{
        extra: [
          # A test asserts order, not an upper bound of wall-clock time (#221).
          {Helyx.Credo.WallClockUpperBound, []},
          # A JSON decode in lib/ code goes through Helyx.JSON.decode/1 (#792).
          {Helyx.Credo.JSONDecode, []},
          # The test exceptions are fixtures named for the message they make, not
          # a naming strategy of the code.
          {Credo.Check.Consistency.ExceptionNames,
           files: %{excluded: ["test/", "plugins/bundled/test/"]}},
          # A .ex file has at most 400 lines of code; docs, comments and blank
          # lines do not count (#294). The list only shrinks: a listed file
          # must not grow, a file under the limit loses its entry, and a file
          # under its count lowers it.
          {Helyx.Credo.FileLength, []}
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
