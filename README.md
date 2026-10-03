# Helyx

```
 ! Highly experimental, use at your own risk !
```

**A BEAM-native substrate for malleable software.**

Helyx is an Elixir framework for building agent-native, stateful products. A product adds Helyx as a dependency, selects plugins, and adds its own domain code. Users can talk to a product and change how it works.

## Shape

Helyx has four kinds of components.

| Component | Elixir form | Role |
|---|---|---|
| Core | `Helyx.Core` | Registers, resolves, and supervises plugins. |
| Interface | `Helyx.<Interface>` | Defines a public API and the callbacks a plugin must implement. |
| Plugin | `<Root>.<Interface>.<Name>` | Implements an interface or adds behaviour through an extension point. Bundled plugins use the `Helyx` root, for example `Helyx.Provider.OpenAI`. External plugins use their own root, for example `Acme.Provider.Bedrock`. |
| Product | `<ProductName>` | Uses Helyx, selects plugins, and owns domain code. |

Core stays small. It contains only plugin registration, OTP supervision, and interface dispatch.
Everything else, including memory, tools, model context, compaction, transports, and user interfaces, is a plugin.

The plugins that ship with Helyx live in one Mix project, `plugins/bundled` (app `helyx_plugins`). A product depends on it and registers the modules it wants. A plugin with a heavy or native dependency, such as the TUI on `ex_ratatui`, exists only when the product also lists that dependency (`docs/adr/0005-one-project-for-bundled-plugins.md`). External plugins are separate packages under their own module root.

## Architecture

The server owns agent and session state. A client holds a rendered copy of it, built from the event stream. Transport plugins are planned. A local client and the server run in one BEAM node and use OTP messages.

```text
Clients (TUI, web, native)
  ↕ Transport plugin (planned)
Server
  ├── Agent processes (OTP supervised)
  ├── Plugins (provider, tools, model context, compaction, ...)
  └── Event stream (every client renders from events)
```

## License

MIT
