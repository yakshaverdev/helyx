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
Everything else, including memory, tools, model context, and compaction, is a plugin.
The interfaces are `Helyx.Provider`, `Helyx.Tool`, `Helyx.ModelContext`, `Helyx.Compaction`, and `Helyx.Memory` (`docs/adr/0009-memory-interface.md`).
A transport, such as the planned `Helyx.Transport.WebSocket`, is a client of the session API in the same node, not a plugin (`docs/adr/0008-client-server-wire.md`).
A user interface, such as the TUI, is a client host: it uses the session API and is not registered as a Core plugin.

The plugins that ship with Helyx live in one Mix project, `plugins/bundled` (app `helyx_plugins`). A product depends on it and registers the modules it wants. The project also holds client code that is not a Core plugin, such as the TUI in `plugins/bundled/clients/tui` (`docs/adr/0005-one-project-for-bundled-plugins.md`). External plugins are separate packages under their own module root.

## Architecture

The server owns agent and session state. A client holds a rendered copy of it, built from the event stream. The end state is one long-running server that owns the sessions; the TUI, web and native apps, and bots are its clients over one wire: WebSocket with JSON frames (`docs/features/wire-protocol.md`, planned). Today a local client and the server run in one BEAM node and use OTP messages.

```text
Clients (TUI, web, native)
  ↕ the wire: WebSocket, JSON frames (planned)
Server
  ├── Agent processes (OTP supervised)
  ├── Plugins (provider, tools, model context, compaction, memory)
  └── Event stream (every client renders from events)
```

## License

MIT
