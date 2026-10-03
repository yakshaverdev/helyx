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
          # A .ex file has at most 400 lines (#294). The list only shrinks: a
          # listed file must not grow, and a file under the limit loses its
          # entry.
          {Helyx.Credo.FileLength,
           [
             allowed: %{
               "lib/helyx/session/server.ex" =>
                 {616,
                  "the GenServer callbacks and the turn and wait transitions of one session process"},
               "plugins/bundled/lib/helyx/provider/codex.ex" =>
                 {532,
                  "the Codex turn, thread, interrupt, and steer state over one JSON-RPC id table"},
               "plugins/bundled/lib/helyx/provider/claude_code.ex" =>
                 {557, "the Claude Code program, turn, steer, and interrupt flow"}
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
