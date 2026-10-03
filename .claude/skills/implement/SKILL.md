---
name: implement
description: Implement a ticket with TDD, then ship it. Use this instead of mattpocock-skills:implement in this repo.
---

# Implement

Implement the ticket the user names. Fetch it with `gh issue view <n> --comments`.

Use `/mattpocock-skills:tdd` at pre-agreed seams. Run single test files as you go and the full suite once at the end.

When the ticket's acceptance criteria are met, invoke `/ship`. Do not run a review or commit any other way.

Before you make code crash on a state, or remove a check for a state, find every input path that can make that state (the disk, the terminal, a provider, a client) and probe each one. A ticket that calls a state unreachable or bug-only states a claim, not a fact. A probe that reaches the state stops the change: report it.
