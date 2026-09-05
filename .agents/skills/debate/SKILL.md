---
name: debate
description: Run competitive multi-agent debates over hub IRC to settle technical designs. Covers open or assigned positions, turn chains, attack/defense rounds, majority voting with scoring, and verdict recording. Use when two or more approaches compete and you want adversarial convergence instead of a single-agent recommendation.
---

# Multi-Agent Debate

Two or more subagents argue a technical question over hub IRC through pitches, attacks, counters, and votes. Parent orchestrates, scores, judges, and records the verdict. Battle-tested shape: 2 agents × 4 rounds for binary choices, 5 agents × 8 rounds (40 turns) for open invention.

## Setup

- **Spawn competitors with `task`.** Each item: stable name (≤32 chars), full brief (Target/Change/Acceptance). No overhead: read-only unless the debate needs otherwise; skip builds/tests/formatters.
- **Open or assigned positions.** Open (invent + advocate + attack, best for unexplored spaces) or assigned (steelman a platform, best for binary choices). State which in the shared `context`.
- **Shared context carries:** the goal, non-negotiable decisions (never relitigated), hard scope exclusions (violations void the turn), the objective function (what "better" means — e.g. max fps, not min bytes), grounding rule (every claim cites repo file/symbol or named external source), message caps (≤15-20 lines, bullets).

## Venue and turn protocol

- **Hub IRC is the venue.** Agents `hub list` to resolve exact roster IDs, `send` to debate, CC Main on substantive turns. Parent monitors via `wait`/`inbox`, never polls.
- **Fixed turn order, chained.** Name the chain (e.g. Flint→Slate→Ember→Moss→Tide); each posts after its predecessor's round message is visible; first posts on Main's ROUND signal. Chain discipline prevents pileups without serializing through the parent.
- **Broadcast hygiene.** Round signals go to `all` ONLY while every live peer is a debater — never broadcast steering when idle agents exist (wakes them; they may act). Prefer addressing live job IDs.
- **Every turn must advance:** new pitch (with the math), attack (counter-evidence), or defense/concession. No repeats. Concessions are first-class output — record who conceded what; they become verdict constraints.

## Rounds

1. **Pitches** — one design per agent with perf/cost math.
2. **Attacks** — weakest-3-claims rebuttals, new counter-evidence required.
3. **Counters** — point-for-point answers; concede explicitly what can't be defended; name one unkillable claim.
4. **Vote** — parent posts a numbered ballot of live ideas; each agent votes adopt/reject + one-line reason. Majority adopts.
5. **Advocacy** — contest close votes (3-2/4-1) with new evidence only; restate votes. Optional mesher/scope additions go here with a snap vote.

Steering interrupts (objective changes, new scope, research tips) relay immediately via `hub send` — they apply to pending turns too.

## Scoring

- **+1** when the group adopts your idea. **+1** when the group rejects a rival idea you primarily attacked (first lethal attack gets the credit; corroborators don't).
- Majority rules; ties and lone dissents get recorded with their evidence, not discarded.
- Announce the running scoreboard at vote time and the final score at close-out. Concession messages from losers are good hygiene — solicit them.

## Verdict

- Write winners to the designated file: adopted items as an ordered plan, rejected items with their kill reasons, scoreboard, and open dissents with evidence.
- If a verdict block lands mid-section, relocate it the same turn (cut + paste via registers).
- Losers' valid caveats survive as gate conditions (e.g. "adopt X only where profiling shows Y"), not footnotes.
- Verify after writing: headers grep + spot-read. Confirm losing agents' completion reports match the recorded tally before closing.
