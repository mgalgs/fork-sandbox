# Ideas parked, not promised

Designs that came up in real use and were deliberately not built yet.
Each entry records the idea, why it was parked, and what would justify
pulling the trigger — so the next time a use case rubs against the same
limitation, the thinking is already here instead of re-derived. Entries
are written timelessly; when one is built, it moves to real docs and a
line here says where it went.

## Multi-implementer block, with an integrator

One handoff, fanned out to N implementers, each on its own branch with
its own review loop; an integrator evaluates the branches that come
back, produces the chosen implementation, and either returns it or fans
out another iteration with new instructions:

```
orchestrator ─→ integrator ─┬─→ [implementer A: reviewer⇄implementer] ─┐
        ^                   ├─→ [implementer B: …]                     │
        |                   └─→ [implementer N: …]                     │
        └───────────────────────── integrate / iterate ←──────────────┘
```

What the design discussion settled before parking it:

- **The integrator's default job should be judging, not merging.**
  Semantically merging N independently-coherent implementations breaks
  exactly at the graft points. Two cheaper policies dominate:
  *tournament* (pick one branch wholesale) and *pick-then-patch* (pick
  the winner, recast the losers' good ideas as findings, and run a
  normal fix leg on the winner's branch). Pick-then-patch reduces the
  integrator to a judge emitting a verdict — and findings-into-a-fix-leg
  is machinery the review loop already has.
- **The block only pays where there is design freedom.** The coder-mode
  discipline of deciding every open question before delegating makes N
  implementers converge, so the fan-out wants the opposite handoff
  style: goal and acceptance criteria stated, plan deliberately
  withheld. Tasks with approach-uncertainty (refactors, performance,
  API shape) qualify; mechanical sweeps never do.
- **There is a competing hypothesis worth testing first.** On rounds
  where a self-hosted model types for free, nearly all the measured
  value came from the paid review legs — which suggests review-diversity
  over ONE implementation (the lkml-mode panel) may beat
  implementation-diversity under one judge at the same token spend.
- **The experiment needs no new code.** An orchestrating session can run
  the whole block by hand: launch N implementers off the same
  goal-not-plan handoff on separate branches (deliberately conflicting —
  they are alternatives, not siblings), judge the returns, pick, and
  run a fix round carrying the grafts. The run log scores it against a
  single-implementation round of similar size.

Parked because: token cost is N× the implement-plus-review legs for a
benefit that is unproven against the cheaper lkml-mode alternative.
Trigger: a task where the approach is genuinely contested and one
implementation keeps coming back plausible-but-wrong — run the manual
experiment on it before building anything.

## Pipeline as data (legs in a config, not flags in a script)

The launcher grew its tiers one hardcoded node at a time — implement,
review⇄fix, then the maintainer loop — and each new node costs new
flags, new prompt plumbing, and new surfacing. The flag-space is
saturating. Before the general solution (an agent-graph DSL: persona
per node, decision logic per edge), there is a middle rung:

- **Legs as data.** The launcher already thinks in legs with a prompt
  source, a harness/model, and a loop condition. Making the leg list a
  declarative document (YAML, most likely) that the existing execution
  machinery walks would allow arbitrary linear-and-loop pipelines
  without inventing node personas or edge predicates. The current flags
  become sugar for the shipped default pipeline.
- **The full DSL is the mailing-list mode generalized** — several
  independent seats, decision points, an iterated record — and the
  planned inter-run mail routing (postmaster/maildir) is the transport
  its edges would need. Those two are one project seen from two ends;
  neither should be built separately from the other.

Parked because: one configuration (the three-tier default) still covers
every round run so far, and a DSL built from a single use case encodes
that use case's assumptions. Trigger: the second concrete "it'd be nice
to configure the pipeline this other way" — a shape the leg-list-as-data
rung cannot express with the nodes that already exist, or a
multi-implementer experiment (above) that earns permanence.
