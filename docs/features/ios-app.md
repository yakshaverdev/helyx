# The iOS app

Ticket #919, part of #853 and ADR 0015. Slice 1: the owner's iPhone app over the Rust client kit, first in the Simulator against a server on the same Mac. This doc holds the goal, the views, the surface that the app needs, and the bounds. The decisions of the shared client are in `docs/features/client-kit.md` and the ADRs; this doc states only what the iPhone app adds.

## Goal

The owner enters the address, the port, and the token of a server once. They see the live sessions and the saved sessions, tap one, and read its transcript as it streams. They send a message. While a turn runs they steer, queue a follow-up, or stop it. A tool that asks a question or an approval shows it natively, and the app sends the answer. A return from the background reconnects with no manual step.

The app is the template that a product forks: SwiftUI draws the snapshot and calls the methods of `Connection`; every rule that the desktop app also makes lives in Rust (ADR 0015 §6).

## Interface changes

### What the Swift views need

`clients/rust/ffi` gains four items, each built on the core, so the host parses no JSON and builds no answer itself. Each type is owned, as the existing surface of the bindings is.

| Surface | What it does |
| ------- | ------------ |
| `read_block(json)` | reads the JSON text of a UI block into `BlockView`: `Form` (its text and questions, with each option's label and description and `multi_select`), `Approval` (its text, tool, provider, and arguments), or `Text` (the kind and the text of any other kind, and of a block that the core cannot read). It never fails: a text that is not a block gives an empty kind and the text, cut to `ui_block::MAX_BYTES`. |
| `form_answer(items)` | gives the JSON text of a form answer, from one `FormAnswerItem` for each question in order, with `core::operation::form_answer`. |
| `approval_answer(allow)` | gives the JSON text of an approval answer, with `core::operation::approval_answer`. |
| `SessionState.answering` | the id of the ask that the host answers now: the oldest open ask of a kind that it reads. |

`BlockView` carries the fallback text of a form and of an approval as well as its fields, because the transcript shows that text when the block is not the open ask. The remaining types are `FormQuestion`, `FormOption`, and `FormAnswerItem`, each a copy of the type of `vocabulary` or `operation`.

The tests are `ffi/tests/blocks.rs`: a form, an approval, a kind that the core does not know, a known kind whose fields it cannot read, a text that is not a block, a text at the bound of a block and over it, each answer, and the open ask of a list.

### The open ask

The host answers `SessionState.answering`, the oldest open ask whose request has a kind that the core reads, `form` or `approval`. The desktop app follows the same rule (`clients/rust/app/src/ask.rs`, `Panel::answering`); #919 does not move that code, and a later ticket makes the app call the function of `ffi`. Until then the two hosts follow one stated rule, and #919's test checks it on the side of the bindings.

### The app

`clients/ios/` holds the SwiftUI app, `xcodegen`'s `project.yml`, `build.sh`, `test.sh`, and `README.md`. `build.sh` builds the static library of `helyx-client-ffi` for `aarch64-apple-ios-sim` (`device` builds `aarch64-apple-ios`), runs `ffi/bindgen.sh`, copies the Swift file, the header, and the module map into `Bindings/` and the library into `Rust/`, runs `xcodegen`, and runs `xcodebuild build`. `test.sh` runs `build.sh`, then `xcodebuild test` for an iPhone simulator. Each script writes a log file that Git ignores and prints `passed` or `failed`. The project, the copied bindings, the library, and the build products are not committed.

`README.md` states the two places of a rename: `project.yml` for the name and the bundle identifier, and the icon set of `Assets.xcassets`.

## The views

Each view is one small file under `clients/ios/Helyx/`; `RootView` chooses between them.

1. **Settings** (`SettingsView`). The address, the port, and the token, which the token field hides. `Connect` saves them and opens one connection. With no settings the app starts here. A wrong address shows the text of `NetError`, and the settings screen stays open; a port that is not 1 to 65535 is refused in the field. A server in use can be replaced from the list, and `Cancel` keeps it.
2. **Sessions** (`SessionsView`). The line of the connection and the line of the follow, then the live sessions and the saved sessions newest first, a folder field with `Start`, and `More` when `saved_next` is set. A pull to refresh asks `live_sessions()` and `saved_sessions(nil)`. A tap follows a live session or resumes a saved one.
3. **Session** (`SessionView`, `TranscriptView`, `UiBlockView`). The rows of `SessionState.rows` and the partial message: a user message in a tinted box at the trailing edge, an assistant text with its inline Markdown shown (bold, italic, code, links; block Markdown stays as written), a thinking block as one line that a tap opens, a tool call with its name, its arguments in a monospaced box, and its result or `awaiting result`, and an orphan result. The UI blocks of a result and `SessionState.ui_blocks` go through `read_block`: a `Text` view shows its text, and a form or an approval that is not the open ask shows its text. The notices follow the rows. The list scrolls to the newest row while the reader is at the bottom, and stays where it is when the reader scrolled up.
4. **Composer** (`ComposerView`). A field of several lines. With no turn running, `Send` sends a prompt; while one runs (`SessionState.running`), `Send` steers, `Follow up` queues a follow-up, and `Stop` aborts. A send empties the field at once and shows the message as pending; an outcome of its number removes the mark, and a failure puts the text back with the reason. The counts of `SessionState.queue` are one small line.
5. **Ask** (`AskView`). The open ask takes the place of the composer. An approval shows the tool and its arguments, with `Allow` and `Deny`. A form shows each question with its options: a single pick is a list with one row checked, and it starts on the first option, as the cursor of the desktop ask does; a multiple pick is a list of rows that toggle; each question has an `Other` field. A single pick sends the checked label, or the Other text, which replaces it. A multiple pick sends its marked labels in option order, and combines them with the Other text. `Send` waits until every question has a label or a text, and the answer goes through `form_answer` or `approval_answer` and `Connection.answer`. An answer that the bindings refuse leaves the ask open and shows the reason.
6. **Life cycle** (`Store`). One `Connection` for the settings in use, held by one `@MainActor` observable store. The listener puts each snapshot in a mailbox and the main actor takes the newest, so the store keeps one snapshot. When `scenePhase` becomes `.active` after a background, the store calls `became_active()` once; an active scene with no background before it calls nothing. A change of the settings drops the connection and makes a new one. The store loads the settings from `UserDefaults` and the Keychain at launch.

## Bounds

The app draws one snapshot, and the core bounds it (`docs/features/client-kit.md`, "Bounds").

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| snapshots in the app | one: the mailbox keeps the newest, and a draw takes it | the states between two draws are skipped | `Store`, `SnapshotMailbox` |
| the arguments of a tool call and a result text | 4,000 characters, with a `more` control | the rest shows after `more` | `Bounds.shownText` |
| the body of an ask | 320 points that scroll, so the Send button and the transcript keep their place | the body scrolls | `Bounds.askHeight` |
| the text of a UI block | `ui_block::MAX_BYTES` (65,536 bytes), cut at a character boundary by `read_block` | the text is cut, with no marker | `read_block` |
| pending sends | the request bound of one connection, 16 (`connection::MAX_IN_FLIGHT`); the layer refuses a further one with `Refusal::Busy` (`net::BUSY`), and an answer of an ask counts too | a 17th send gets a failed outcome and no second mark | `Store.pending`, `connection::MAX_IN_FLIGHT` |
| the composer | unbounded human input, as in the desktop app; a send is bounded by the core at 4 MiB | the bindings refuse it, the text stays, and the line names the reason | `Store.send`, `operation::MAX_TEXT_BYTES` |
| the settings | the address must parse as an IP address and the port is 1 to 65535; the token is unbounded human input and an empty one sends no proof | the address or the port is refused before the thread starts, and the settings screen shows why | `Connection::new`, `SettingsView` |
| the transcript | no bound of its own, as in the desktop app: it grows with the session | the list lays out only the rows in view | `TranscriptView` |
| the rows of the transcript | one comparison of the state for each change, O(rows), to scroll to the newest row while the reader is at the bottom | the comparison costs the rows of the state, and the core bounds each snapshot | `TranscriptView` |
| the reconnect of an active app | one `became_active` for each return from the background, and the layer reconnects at most once each 1,000 ms | a second active scene calls nothing | `Store.scenePhase`, `net::run` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the network thread and its socket | `Connection::new`, at the launch for a saved server or at `Connect` | the store, which holds the `Connection` | a change of the settings drops the connection, whose drop ends the thread; the app's end drops the store | the process ends, and the socket closes with it | a change of the settings, as above |
| the Keychain item of the token | `Keychain.save` at `Connect` | the system Keychain, for this app's bundle identifier: after the first unlock, on this device only | a later save replaces it; the item stays after the app ends | it stays, and the next launch reads it | it stays |
| the address and the port | `SettingsStorage.save` at `Connect` | `UserDefaults` | a later save replaces them | they stay | they stay |
| the snapshot | the listener of the connection | the store's mailbox and its one published snapshot | the next snapshot replaces it | it dies with the store | the settings change drops it |

The Keychain item is one generic-password item of the app, with the bundle identifier as its service, so a product that changes the identifier reads its own token. An app with no signature has no Keychain, so `build.sh` signs the Simulator build to run locally, which needs no team. A save that the Keychain refuses shows a line, and the next launch asks for the token again.

The server sends no change of the two lists, so the app asks them at the connect, at a pull, and each time the list screen opens (`Store.showList`). A live list on the wire is ticket #957.

## Replaced mechanism

None: the app is new, and the surface of the bindings gains items that no host used.

## Out of scope

- Pairing and TLS to a remote server, which #956 adds; the app uses a token over the local network.
- Push notifications.
- The board.
- The bare shell and the safe mode of ADR 0015 §8 (#932).
- Over-the-air install of a build (#930).
- An icon set: the asset catalog holds the slots and no image.
- The Android app and the web client.
- No wire change, no fixture change, and no Elixir change.
