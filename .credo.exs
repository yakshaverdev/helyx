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
          {Helyx.Credo.WallClockUpperBound, []},
          # A JSON decode in lib/ code goes through Helyx.JSON.decode/1 (#792).
          {Helyx.Credo.JSONDecode, []},
          # The test exceptions are fixtures named for the message they make, not
          # a naming strategy of the code.
          {Credo.Check.Consistency.ExceptionNames,
           files: %{excluded: ["test/", "plugins/bundled/test/"]}},
          # A .ex file has at most 400 lines (#294). The list only shrinks: a
          # listed file must not grow, a file under the limit loses its
          # entry, and a file under its count lowers it.
          {Helyx.Credo.FileLength,
           [
             allowed: %{
               "plugins/bundled/lib/helyx/provider/codex.ex" =>
                 {481,
                  "the Codex turn, thread, interrupt, and steer state over one JSON-RPC id table"},
               "plugins/bundled/lib/helyx/provider/claude_code.ex" =>
                 {507, "the Claude Code program, turn, steer, and interrupt flow"}
             }
           ]}
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
