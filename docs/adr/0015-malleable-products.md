# Malleable products: the product model, the bare layer, and the build flow

Status: accepted on 2026-11-10, ticket #926. The decisions are the owner's, from a design discussion of 2026-11-10, recorded in the roadmap #925; this ADR states them with their reasons and changes no code.

User story: a developer runs `helyx new alyxa --platforms macos,ios --plugins ...` and gets a product repo. The product runs on a Linux server and in apps on the developer's Mac and iPhone. In the app, the developer asks the agent for a change: a new screen, a new tool, a new name. The agent edits the product repo and commits. A server change reloads in place. A native change is built on the Mac, and the phone installs the new build from an **Install** button. When a change breaks the app, the app still starts with the agent chat, and the developer asks for a rollback.

## Context

- A product is independent software built on Helyx that selects plugins and owns its domain code (`CONTEXT.md`, "Product"). Today the products live in the Helyx repo, under `apps/<name>/`, one Mix project each (`AGENTS.md`, "Repository layout").
- `Helyx.Hub` is a bundled module that a product starts beside the transport, and it owns identity, records, routing, wake-ups, and, later, executor assignment (ADR 0010).
- A tool can return UI blocks of a typed vocabulary, which a client renders natively with no client build for a new mode (ADR 0011).
- Remote hands run the tools and the provider process of a session on a runner, such as a laptop, over the wire (ADR 0012). Nothing built yet assigns a session to a runner (#928).
- The client kit is a shared Rust core, `helyx-client-core` (`clients/rust/core`), and a GPUI desktop app, `helyx-desktop` (`clients/rust/app`); the mobile apps were left for later (#860, `docs/features/client-kit.md`). #860 replaced the shared client core in KMP that the roadmap #853 planned (2026-11-06).
- The approval gate, `Helyx.Hook.Approval`, allows, denies, or asks the user about a tool call by a rule on its tool name and provider (#882, `docs/features/approval-gate.md`). Its question goes to a client through `Helyx.Hook.ask/1`, and a client answers with the `answer` operation of the wire; no bundled tool answers an ask.
- The coordinator plugins let a session start and drive child sessions (#859, `docs/features/coordinator.md`).

## Decision

### 1. A product has four layers

1. **Core**: the agent loop.
2. **Plugins**: the bundled plugins that the product picks, and its own. A **mode** is a named list of plugins: data, not a new interface.
3. **A default agent**: in the app, it changes the product when the developer asks.
4. **A template for each platform** that the product opts into.

Reason: everything is a plugin already (`AGENTS.md`, "Key design constraints"). The product model adds no interface: a mode is a list, the default agent is a mode, and a template is generated code in the product repo.

### 2. Product code lives in its own repo

A product lives in its own repo, not in the Helyx repo. `helyx` becomes a standalone CLI, and `helyx new <name> --platforms ... --plugins ...` creates a product repo (#933).

Reason: a developer must create and change a product without a clone of Helyx, and an agent that changes a product must not touch Helyx.

### 3. Templates work like Create React App

The product owns the generated code: its screens, its name, its icon. The bare layer (§6) stays a versioned Helyx dependency.

Reason: the agent changes the product's screens as product code, and a new Helyx version reaches the product through a dependency update, not through a merge into generated code.

### 4. The developer is the user of the default agent

The default agent changes the product for its developer. Changes by an end user are out of scope.

Reason: an agent that changes the code of the app that it runs in is a developer tool. An end user who changes a product needs a sandbox, an approval model, and a distribution path that the first version does not have.

### 5. The first version serves the owner only

The first version serves a very small user base: the owner. It has no App Store: the builds are ad hoc builds. App Store guideline 2.5.2 forbids an app that downloads code that changes its features, so the in-app agent is a feature of a developer build. Screen-level server-driven UI waits until the native rebuild loop is too slow; the UI blocks of ADR 0011 stay as they are.

Reason: one user accepts a native rebuild for each native change, so the first version needs no layout language on the wire, and ADR 0011 already lets a new mode show its data with no client build.

### 6. The client stack

- A shared Rust core, `helyx-client-core`, GPUI for the desktop, and SwiftUI for iOS. UniFFI connects the Rust core to Swift (#931).
- Logic that both apps need goes into Rust, not into the views: the composer state, the operations, the network layer and its reconnect rules (#920, #931).
- Linux and Windows desktop apps come later, on GPUI.
- The wire protocol and its fixtures are the contract of every client. A React Native template, `ios-rn`, may come later, if a product needs live reload without a native rebuild; it needs no server change.

Reason: GPUI keeps one desktop codebase for macOS, Linux, and Windows. SwiftUI is the native toolkit of iOS. The Rust core keeps the two from writing the same logic twice.

### 7. The build flow

- The Helyx server runs on a Linux VPS. The VPS holds the product repo, which is the source of truth, and the agent session.
- For a native change, the main agent commits, and the coordinator (#859) starts a child session whose hands are the owner's Mac: remote hands (ADR 0012, #927) on a runner that Hub assigns (#928).
- The Mac session builds the commit (#929). For iOS it signs an ad hoc `.ipa` and uploads it to the VPS. The VPS serves it over HTTPS for an `itms-services` over-the-air install, which an **Install** button in the app starts (#930). For macOS it builds and restarts the desktop app.
- When no Mac runner is connected, the build fails at once with a clear message ("Mac offline"). The agent starts the build again when the Mac connects. There is no queue.

Reason: only a Mac builds and signs an iOS app, and a laptop is not always on. The session and the repo stay on the VPS, so a closed laptop stops only a build, not the agent. A build that fails at once tells the agent and the developer the state; a queue would hold work for a machine that may not come back.

### 8. The bare layer and the full layer

Like Emacs and `emacs -Q`: a bad change in the product must never lock the developer out of the agent (#932).

- **The bare layer** is everything that Helyx ships: Core, the transport, Hub, the bundled plugins, the default agent, the client core, and the app shell (the agent chat and rollback). **The full layer** is what the product repo adds.
- The bare layer is a set of dependencies, not source code in the product repo, so the agent changes only product code.
- **Eject** is the explicit opt-in to known danger: it copies one bare piece into the product repo. An eject needs the developer's approval through `Helyx.Hook.Approval`, which the agent cannot answer. After an eject, safe mode no longer covers that piece (#932).
- **The edit guard.** The approval gate refuses agent edits outside the product repo, and `bash` in the repo goes through the same check. It guards against accidents, not against a hostile agent: the agent runs as the same OS user. The gate's rules match a tool name and a provider today; the rule on the path of an edit is new work of #932.
- **Server safe mode.** The server starts without the product plugins. The product plugins run under their own supervisor, so a crash of them does not stop the bare server, and the error reaches the chat. A hot reload replaces a module only when the new code compiles.
- **App safe mode.** After 2 launches that crash before the app is healthy, the app starts in the bare shell, with no product views.
- **Last known good.** A build is healthy when the app connects, shows the chat, and runs 30 seconds without a crash; the app tells the server, which marks the build as good (#930). Rollback is a `git revert` to that commit and a reinstall of that build.

Reason: the developer reaches the agent only through the app and the server, and the agent edits both. If a product change could break the chat, one bad change would end the loop that fixes it. Dependencies that the agent does not edit, a separate supervisor, and a bare shell keep the chat out of reach of a product change.

### 9. What Core does not know

Templates, platforms, builds, the product repo, eject, safe mode, the bare and full layers, and the last known good build are not Core constructs. Core code does not name them (`AGENTS.md`: Core knows only interface constructs).

- A mode is a list of plugins that the product passes to Core; Core sees plugins.
- The build tools are tools of a runner (#929). The assignment of a session to a runner is Hub (#928, ADR 0010 §2). The build store, the install route, and the last known good record are outside Core (#930).
- The edit guard and the eject approval are rules of the approval hook plugin.
- Server safe mode starts Core with the bare plugins and adds the product plugins under their own supervisor. If that needs a Core change, the feature doc of #932 states it in terms of plugins and supervision, never as a product or a safe mode.
- `helyx new` and the templates belong to the CLI (#933).

## Bounds

| Input | Bound | Where |
|---|---|---|
| launches that crash before the app is healthy | 2; then the app starts in the bare shell | app shell (#932) |
| healthy build | the app connects, shows the chat, and runs 30 seconds without a crash | app shell and server (#930) |
| a build with no Mac runner connected | fails at once; no queue | Hub assignment (#928) |

The feature docs of the follow-up tickets state the other bounds: the build time, the size of the build output and of the `.ipa` (#929), and the number of builds that the server keeps for each product (#930).

## Considered options

- **Screen-level server-driven UI now (A2UI, OpenUI).** Rejected for the first version: it serves the owner only, so native rebuilds are acceptable, and the UI blocks of ADR 0011 stay. A2UI has native renderers, but its SwiftUI renderer is alpha and its v1.0 is a release candidate (a2ui.org, read 2026-11-10). OpenUI (thesysdev/openui) is web-first, and its Swift SDK is an unmerged pull request (#1521, opened 2026-10-30). Its idea of one component contract that generates the prompt is noted for later.
- **SwiftUI on macOS.** Rejected: the owner keeps GPUI for the desktop, so that Linux and Windows desktop apps stay possible. The cost is accepted: two UI codebases, and models that know GPUI less well than SwiftUI (#934 adds a GPUI guide to the default agent). Shared logic goes into the Rust core.
- **React Native first.** Rejected for now. A later `ios-rn` template may come, if a product needs live reload without a native rebuild (§6).
- **Building iOS on Linux (xtool).** Rejected: unproven for a Rust core with UniFFI under SwiftUI.
- **The whole agent session on the Mac.** Rejected: a closed laptop would stop the agent. The VPS keeps the session and the repo; only builds go to the Mac.
- **The App Store.** Rejected for the first version: guideline 2.5.2 forbids an app that downloads code that changes its features, so the in-app agent is a developer-build feature, with ad hoc builds.
- **A build queue for an offline Mac.** Rejected: the build fails at once, and the agent starts it again when the Mac connects (§7).
- **The bare layer as source in the product repo.** Rejected: the agent would edit Helyx code with every product change, and a bad edit could break the chat that repairs it. Eject is the explicit path for one piece (§8).

## Consequences

- `CONTEXT.md` gets the terms product (revised to the four layers), mode, template, bare layer, full layer, eject, safe mode, and runner.
- The extension surface does not change.
- Accepted hole: the edit guard and the eject approval do not stop a hostile agent. The agent runs as the same OS user as the server, so its commands can reach what that user can, the server's credentials included.
- Accepted hole: a native change needs a rebuild and a reinstall; until a Mac runner connects, no native change reaches the app.
- Accepted hole: an ejected piece is product code, and safe mode no longer covers it.

The follow-up tickets build it, each with its own feature doc from `docs/features/TEMPLATE.md` before its build. #927 to #930 are the build path, in this order; #931 is needed by #919.

1. #927: remote hands, the feature doc `docs/features/remote-hands.md` and the build of ADR 0012.
2. #928: executor assignment in Hub, a session on a named runner or on a runner that reports a tool.
3. #929: the `ios_build` and `desktop_build` tools of a Mac runner.
4. #930: over-the-air install of iOS builds, and the last known good build.
5. #931: the network layer in a shared crate, and UniFFI bindings for Swift.
6. #932: the bare and full layers, safe mode, the edit guard, and eject.
7. #933: the standalone `helyx` CLI and `helyx new`.
8. #934: the default agent of a product.
9. #920: the composer and the operations, in the Rust core first, then in GPUI and SwiftUI.
10. #919: the iOS app, the SwiftUI template over the Rust core.

Out of scope: changes by an end user; the App Store; screen-level server-driven UI; a React Native template; the distribution of the CLI and the update of a product to a new Helyx version (open questions of #933).
