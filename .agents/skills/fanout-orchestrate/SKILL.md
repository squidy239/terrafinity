---
name: fanout-orchestrate
description: Run parallel subagents on disjoint scopes without them clobbering each other. Covers file ownership, section ownership, gate discipline, and broadcast hygiene. Use when dispatching two or more workers or researchers in one phase.
---

# Fanout Orchestration

Parallel workers share no context and race on shared files. Every collision in this session came from violating one of these rules.

## Ownership

- **One worker per file.** Same-file edits from two workers are not guaranteed to merge. If two fixes land in one file, assign both to a single worker or serialize them.
- **Call-site span stays together.** A fix touching a callee plus its callers (e.g. signature change) belongs to one worker owning all those files, never split across workers.
- **Shared append-only files get section ownership.** Each researcher owns exactly one heading; it creates the heading once at the tail if absent, then edits only inside it. Nobody touches another section or the file head.
- **Read-only scouts may overlap workers** only on files no worker owns. Re-check ownership before each wave.

## Gates

- **Workers never verify, lint, or format.** Every dispatch says: skip gates/formatters/tests, edit only. The orchestrator formats once and verifies once across the union at phase end — never mid-flight while siblings still edit (builds then prove nothing).
- **Wait with ID filters** so unrelated completions don't hijack the wakeup. Never bare-wait when background researchers are running.

## Broadcast hygiene

- **Never broadcast steering to idle agents.** A message to `all` wakes yielded workers and they may edit. Address live job IDs only; tell idle agents to stop editing in a separate, explicit message if needed.
- **Freeze idle editors** the moment stray edits appear: one message ordering no further file changes, then verify the tree before continuing.

## Verification order

Scout evidence → fix batch → green build → hostile review → findings fixes → green build → close. Review findings become a new fix batch under the same ownership rules; re-review only the critical path, not the whole union.
