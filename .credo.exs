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
                 {1027, "the turn, tool, steer, and wait logic of one session process"},
               "plugins/bundled/lib/helyx/provider/codex.ex" =>
                 {1145, "the Codex app-server protocol in one harness provider"},
               "plugins/bundled/lib/helyx/provider/claude_code.ex" =>
                 {1000, "the Claude Code stream-json protocol in one harness provider"},
               "plugins/bundled/lib/helyx/tui.ex" =>
                 {841, "the terminal loop, input, and rendering of the TUI"},
               "lib/helyx/session/file.ex" =>
                 {643, "the session file format, reader, and writer"},
               "lib/helyx/session.ex" => {453, "the public session API with its contract docs"},
               "plugins/bundled/lib/helyx/provider/openai.ex" =>
                 {485, "the OpenAI request and stream parser"},
               "plugins/bundled/lib/helyx/watchdog.ex" =>
                 {440, "the program watchdog and its process-group protocol"},
               "lib/helyx/session/provider_process.ex" => {416, "the provider process loop"}
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
