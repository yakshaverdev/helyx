# 2026-10-17: #490, the Helyx summary of a model provider's transcript

## Done

- Feature doc `docs/features/summary-compaction.md`, from the owner decisions of the ticket.
- Core: `Helyx.Summary` and its `Plan`; the `{:summarize, plan}` and `{:error, text}` returns of `Helyx.Compaction.compact/2`, checked in `Helyx.Session.Stream.prepare/4`; the summary call in its own provider process (`Helyx.Session.Server.Summary`); the context build moved out of `TurnLoop` into `Helyx.Session.Server.Prepare`; the summary entry of the session file; `/compact` on a model provider; the overflow retry in `Helyx.Provider.Loop`.
- Bundled plugin `Helyx.Compaction.Summary`; the coding agent registers it. `Helyx.Compaction.None` stays the default no-op.
- Review: three full rounds (`docs/reviews/2026-10-17-ticket-490.md`).

## What broke

- `origin/master` moved three times during the work (#663, #664, #671). The branch was rebased before rounds 1 and 2. #663 changed `Helyx.ModelInfo.lookup` to take the catalog id of the provider, so the plugin looks up only the `:models` config.
- `turn_loop.ex` went over 400 lines; the context build moved to `Prepare`.

## Assumptions (owner away)

- The plugin frames the summary: Core passes `opts[:summary]` and the whole transcript.
- The 64 KiB cap is a Core bound, checked in the session and in the reader.
- `compact/2` can return `{:error, text}`, for the clear error of a manual `/compact` with an unknown window.
- The trigger is nil for a provider that keeps its own history, and for the build after a summary or a failed one.
- A failed summary outside a `/compact` gives a notice, and the turn goes on with the previous context (decision 4 of the ticket body).
- Only a summary call that ends with `:end_turn` gives a summary.
- The estimate is #488 with no summary, else a quarter of the bytes of the context to send.

## Next

- An observed overflow response of a real endpoint, so a bundled provider can give `{:context_overflow, _}`.
- The usage and the cost of the summary call.
