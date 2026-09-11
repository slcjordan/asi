# Shadow loop

Personal workflow events into a manual queue by default, a sandbox that shadows
the same events, and a path from labeled traces to automation that has to earn
its place.

Written against openclaw `2026.8.1` and the `asi-dev` release on `k3d-halo-dev`,
2026-09-10. Companion to [gateway-fleet](gateway-fleet.md), which this depends
on for exactly one step -- see [Relationship to the fleet](#relationship-to-the-fleet).

## The shape of it

Every event lands in a manual queue. Nothing is automated on day one. A sandbox
running the same code against the same events produces *proposals* that are
never acted on, only labeled. When the record for an event type is good enough,
that type graduates -- to deterministic logic first, to an agent second. The
manual queue stays as the floor.

```
                        ┌──────────────────────────────────┐
 chat    ──webhook──>   │ router                           │
 tracker ──webhook──>   │ mint trace id · sign · fan out   │
                        └───────┬──────────────────┬───────┘
                           100% │                  │ sampled (start: 100%)
                                v                  v
              ┌─────────────────────────┐  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
              │ asi-live                │    asi-sandbox
              │                         │  │                          │
              │ webhooks -> workboard   │    webhooks -> agent run
              │   card (default: human) │  │   real reads, fake writes │
              │   card (automation: []) │    proposed action artifact
              └───────────┬─────────────┘  └ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─┘
                          │                             │
                          │         attached to the live card, by trace id
                          │<────────────────────────────┘
                          v
                  ┌───────────────┐        ┌──────────────────┐
                  │ otel-collector│───────>│ trace archive    │
                  └───────────────┘        │ replay · labels  │
                                           └──────────────────┘
```

The central decision is that **the human queue is the default route, not the
fallback**. The system is correct on day one, can only improve, and never
regresses below manual. It also produces the label set as a byproduct: a card
someone worked is ground truth that cost nothing extra to collect.

The second decision is that **most of this is already in the image**. See below.

The third is that **the sources are not chosen yet**, and nothing here depends
on which they are. What it depends on is their *shape* -- specifically whether
a source's state can be mirrored into a sandbox, which is the split
[Real reads, fake writes](#real-reads-fake-writes) turns on. Two shapes recur
throughout: **tracker-shaped** (issues, tickets, records -- structured state
behind an API) and **conversation-shaped** (chat, threads, mail -- where the
context is the prior messages). Most candidate sources are clearly one or the
other, and that is the only property the design needs from them.

## What the source actually says

Read out of `/app/extensions` in the running image, the same way the A2A
findings in [gateway-fleet](gateway-fleet.md#what-the-source-actually-says)
were. **Unverified at runtime** -- all of it rests on a source read. Confirm
before building on any of it, and re-check on an openclaw bump.

### `workboard` is the manual queue, and the dispatcher

`workboard/openclaw.plugin.json`, `workboard/src/store.ts`,
`workboard/src/dispatcher.ts`

Boards, cards, statuses, positions. 35 tools covering `create`, `claim`,
`move`, `block`, `unblock`, `complete`, `comment`, `attachment_add`,
`reassign`, `stats`. A dashboard contract with `cards.list`, `boards.list` and
`cards.stats` bindings, plus a `dispatch` action verb. That is the swimlane,
and it does not need building.

The part that matters more: a card carries an optional `automation` block --
`skills`, `workspace`, `workspaceAccess`, `maxRuntimeSeconds`, `maxRetries`,
`scheduledAt` (`workboard/src/store-automation.ts`) -- and `workboard_dispatch`
hands ready cards to workers. *Manual by default, automation on specific cards*
is the plugin's native model rather than something layered over it. The
promotion ladder this document describes is, mechanically, deciding which cards
get an `automation` block.

`enabledByDefault: false`, so it needs an explicit entry, and a slot in the
chart's exclusive `plugins.allow` (`values.yaml:94`).

### `webhooks` is the ingress, with real SecretRefs

`webhooks/openclaw.plugin.json`, `webhooks/src/http.ts`

Authenticated inbound routes: each is a `path`, a `sessionKey`, a `secret`, and
an optional `controllerId`. Routes bind external automation to TaskFlows.

Worth noting against the A2A experience: `secret` accepts either a literal or a
proper SecretRef (`{source: env|file|exec|store, provider, id}`), and the plugin
declares a `configContracts.secretInputs` path for `routes.*.secret`. So unlike
`channels.a2a.peers.*.token`, this one is in openclaw's credential surface and
the chart does **not** have to render a literal into the ConfigMap. The
`render.sh` substitution dance that A2A forces is not needed here.

### `workboard_promote` is not the promotion this document means

`workboard/src/store-promote.ts:10`

`promoteReady()` walks cards and advances any whose dependencies are satisfied
-- blocked to ready. It is scheduling, not learning. The name collides with the
concept in this document and the two are unrelated. There is no built-in
"this pattern recurred, automate it" anywhere in the plugin.

`automation-nudge.ts` is likewise narrower than it sounds: a 60s-debounced
per-board nudge fired on card change, with an explicit guard against
self-triggering from cron sessions.

### Probably no channel plugin for whatever gets chosen

The bundled channels are `telegram`, `imap`, `microsoft`, `reef`, `a2a` and the
IRC plugin baked into our own image. That is a short list, and the odds of a
chosen source landing on it are low -- `imap` is the one plausible exception,
for a mail-shaped source.

So assume sources arrive as `webhooks` routes, and that anything outbound --
posting a reply, moving a record's status, acknowledging receipt -- is an HTTP
call the agent makes itself. That is the same shape as the A2A calling
convention already documented in
[gateway-fleet](gateway-fleet.md#calling-convention): `curl`, a token read from
a file on tmpfs so it stays out of the model's context, instructions in
`AGENTS.md`. One pattern, reused.

## Scope: what is actually new

Strip out what the image provides and the build is small. That is the point of
the section above -- the original sketch of this design would have rebuilt three
things that already exist.

| Piece | Provided by | Status |
| --- | --- | --- |
| Manual task queue, swimlane UI | `workboard` | Enable it |
| Webhook ingress, authenticated | `webhooks` | Enable it, add routes |
| Per-card automation dispatch | `workboard` | Enable it |
| Trace correlation key | otel, trace id | Already the convention |
| Variant separation in spans | per-gateway `service.name` | Fleet step 1 |
| **Trace-id minting, fan-out** | -- | **Build: the router** |
| **Sandbox release and isolation** | -- | **Build: values + NetworkPolicy** |
| **Proposal artifact on the card** | -- | **Build: convention + `AGENTS.md`** |
| **Label capture** | -- | **Build: thin** |
| **Trace archive and replay** | -- | **Build: the real work** |

Everything in bold is this document. Everything above it is configuration.

## The router

The one genuinely new service, and deliberately tiny. It terminates each
source's webhook, verifies its signature, mints a trace id, and forwards the
event to one or both namespaces' `webhooks` routes.

It exists for one reason: **the trace id is the join key**, and no upstream
source will mint one. openclaw drops `runId` from exported spans by two
independent mechanisms (`values.yaml:262`), so the trace id is already the
correlation key for everything else in this cluster. Extending it upstream to
the originating event is what lets a sandbox run, a live card, a human outcome
and a span tree all be joined later.

Three consequences worth stating:

- **It ships in pass-through mode first.** Phase 1 has no sandbox, so the
  router forwards to live only. Fan-out is a later config change, not a later
  component. Minting the trace id from day one means the archive is uniform
  from its first row -- retrofitting a join key onto a month of captured events
  is not possible.
- **It is its own release, not part of either namespace.** It has to survive
  both being rebuilt, and it holds the upstream signing secrets, which belong
  to neither side.
- **It is not the router the fleet doc declined.** That decision was about an
  A2A proxy between gateways inside one release. This is ingress fan-out across
  releases. Different layer, no contradiction, and the fleet's caller-side
  variant selection stays exactly as designed.

Signature verification belongs here rather than in the `webhooks` plugin
routes, because the router is the only component that sees the original request
bytes. Downstream, the per-route `secret` is a shared secret between the router
and each namespace -- a different trust boundary, and one that a SecretRef
covers cleanly.

## The sandbox

### Real reads, fake writes

The obvious design -- mirror the world into a sandbox and point non-production
credentials at it -- works for one source shape and fails completely for the
other. This is the finding that should drive source selection rather than
follow it.

**Tracker-shaped sources mirror well.** The state is structured, the API is
syncable, and a parallel project or instance is usually cheap to stand up. A
shadowed event references records that can be made to exist.

**Conversation-shaped sources do not mirror at all.** A shadowed message
references a thread, a channel, people, and a hundred lines of prior exchange.
That context *is* the prior messages, and they live wherever the real
conversation happened. Mirroring it is not merely expensive, it is not
possible -- and an agent handed a message stripped of its thread is being asked
a different question than the one that actually arrived.

Rather than carry an isolation model per source shape, take the one that works
for both:

> **The sandbox holds real read credentials and fake write credentials.**

The agent sees the actual world and cannot touch it. Fidelity is solved at the
cost of a genuine production read token living in the sandbox namespace.

At one user that trade is obviously correct. It is worth writing down that it
does not survive a second one: the moment someone else's events flow through
here, "the sandbox can read everything" stops being acceptable and the mirrored
world becomes the only option. That is the wall this design hits, and it is a
long way off.

### The isolation is credentials, not the namespace

A namespace isolates nothing by itself. The safety argument rests on three
things, and they should be named in the chart rather than assumed:

- **Separate Secrets.** Already per-release, since the Secret is
  `<fullname>-secrets` (`values.yaml:4`).
- **A default-deny NetworkPolicy** in the sandbox with an explicit egress
  allowlist -- the model provider, each source's read API, the collector.
  Nothing else. This is what actually makes "fake writes" true rather than
  aspirational, because it survives an agent that talks itself into using a
  credential it found.
- **Separate PVCs**, free by construction with a second release.

The write credentials being fake is a second line, not the first. An agent with
a real token and no route to the internet cannot use it.

### Failure has to be distinguishable from being wrong

The single largest source of label noise in this design: a shadowed event
references something the sandbox cannot reach, the run fails for environmental
reasons, and it gets labeled bad. Do that for a month and the promotion model
has learned the shape of the sandbox's gaps rather than the agent's competence.

So `could-not-reach` is a first-class outcome, distinct from `wrong`, and it is
the sandbox's job to emit it rather than the labeler's job to infer it. A run
that ends without a proposal artifact is `could-not-reach` by default -- fail
closed, and count those separately. If one event type's `could-not-reach` rate
is high, that is a fidelity bug to fix, not evidence about an agent.

## Labeling

### The unit of output is a proposal, not a trace

If labeling requires reading a trace, it will not happen, and the loop starves
-- this is the failure mode that kills these systems, well before any modeling
question arises. At one user there is no labeling team to fall back on.

So the sandbox's output is a **proposed action artifact**: the diff it would
have committed, the reply it would have sent, the transition it would have
made. Concrete, small, and reviewable in seconds. It is attached to the live
card the human already touched, matched by trace id.

The question that gets answered is *"would you have shipped this?"* -- a
judgment on an artifact, not a comparison against a trace. If an event type
cannot be reduced to a glanceable artifact, it is not ready for this loop, and
that is useful information rather than an obstacle.

### Labels

Five outcomes, deliberately few:

| Label | Meaning |
| --- | --- |
| `ship` | Would have shipped it as-is |
| `ship-with-edits` | Right shape, wrong details |
| `wrong` | Would not have shipped it |
| `could-not-reach` | Sandbox fidelity failure, not an agent judgment |
| *(unlabeled)* | The default, and it must stay cheap to leave things here |

`ship-with-edits` is the interesting one: it is the signal that an event type is
close, and it is what separates "needs a better prompt" from "needs
deterministic logic."

Capture is a `workboard_comment` or an attachment on the card. It stays inside
the tool that is already open.

## Evidence and promotion

### Do the volume arithmetic first

A single person's actionable event flow is perhaps 5-20 events a day. Call
it 300 a month, across maybe eight event types, and a two-arm comparison halves
it again: **roughly 19 observations per arm per month.**

Detecting a difference between a 70% and an 85% win rate at conventional power
needs about 120 per arm. That is six months per comparison, for one event type,
assuming nothing changes underneath -- and things will change underneath.

Two conclusions, and they are the honest ones:

- **There is no statistical layer in v1.** A count table by event type and
  outcome is the appropriate instrument at this scale. "This type has been
  labeled `ship` eight times running, zero otherwise" is a real basis for
  action; a fitted model over 19 points is decoration.
- **Sample at 100%, not a small fraction.** At this volume the model spend is a
  few dollars a day. Sampling down mitigates side-effect risk, but isolation is
  supposed to have handled that already -- if it has, less data is pure loss,
  and data is the scarce thing here.

The corollary is about expectations. Automating an event type at this volume
saves minutes per day. **This is a learning instrument, not a toil-reduction
play**, and it should be built accordingly: spend the effort on observability
and replay, not on promotion machinery that will run a handful of times.

### Replay is the lever

The trace archive's real value is not audit, it is that **a candidate rule can
be evaluated against the entire history instantly.** Write a deterministic
handler for an event type, replay every archived event of that type through it,
and measure agreement with what actually happened -- no deploy, no traffic, no
waiting.

This is what makes the volume problem tractable. It converts "wait six months
for enough samples" into "test against everything that ever happened, now."
Given the arithmetic above, it is the only thing that does, which is why it
outranks the promotion pipeline in the order of work.

It requires the archive to store enough to re-run against: the original event
payload, the trace id, the label, and the proposal artifact. Spans alone are not
enough -- they are bounded identifiers by design (`values.yaml:260`).

### Three targets, three different bars

The original sketch grouped these. They are not alike:

| Target | Evidence needed | Rollback | Verdict |
| --- | --- | --- | --- |
| Deterministic logic | Near-total, but *offline-testable* via replay | Trivial -- delete the rule | First. Highest confidence, cheapest to verify, best payoff |
| Routing rules | Which handler gets an event type | Trivial | With the above; they are the same decision |
| Agent variant | Comparative, needs both arms running | Change one value, roll a pod | Last. Needs the fleet, and the arithmetic above says it is slow |

Deterministic first is not just the safe order, it is the order the evidence
supports: a rule can be proven against history, a variant cannot.

### Keep shadowing what has been promoted

Once an event type routes to deterministic logic, it stops reaching the manual
queue -- and the system goes blind in exactly the place it just automated. A
rule that silently goes stale after an upstream change is undetectable.

So the sandbox keeps running on already-automated types, and the comparison
keeps being recorded. Cheap to state now and expensive to retrofit, because
retrofitting means a gap in the archive across precisely the types that matter
most.

## Data handling

The event sources are unlikely to be wholly yours. Anything work-shaped carries
someone else's words, someone else's records, and someone else's expectations
about where those end up. Assume that, and three decisions become mandatory
before the first event is captured rather than after:

- **`captureContent` is the crux.** It is `false` today (`values.yaml:260`) and
  the comment there explains why. This design requires content -- a proposal
  artifact is content, and replay needs the original payload. Turning it on is
  a deliberate reversal of that decision for this deployment, and the doc should
  not pretend otherwise. Consider keeping it off on the otel path and storing
  content only in the archive, where retention is under this design's control
  rather than the collector's.
- **Retention window, chosen now.** The archive is the whole point, so it will
  grow, and a window chosen after six months is a window chosen after the data
  already exists. `workboard` ships `card-redaction.ts`, which is worth reading
  before inventing anything.
- **What leaves the cluster.** Prompt content reaches the model provider. That
  is unavoidable for an agent, and it is a different decision from what is
  retained at rest. Write down both.

None of this is a blocker. All of it is much cheaper decided in advance.

## Relationship to the fleet

The two documents interlock at exactly one point, and the ordering is forced.

**Fleet step 1 must land before any capture begins.** That step renames the
StatefulSet and strands `data-asi-openclaw-0`
([blast radius](gateway-fleet.md#blast-radius)). `workboard` keeps its cards in
sqlite on openclaw's state directory, on that PVC
(`workboard/src/sqlite-store.ts`). So every card, label and archived trace
accumulated before the refactor is destroyed by it. The fleet doc accepts that
cost on the grounds that there is no production and the cluster is rebuildable
-- which is true today and stops being true the moment this design starts
collecting. Doing it now is free. Doing it in a month costs the month.

**Fleet steps 2-5 are not needed until the very end.** A2A, `git-a`, the
calling convention and `git-b` matter only for running two agent variants to
compare, which is the last phase here and the one the arithmetic says is
slowest to pay off.

**The router is not a fleet concern.** Stated again because the two are easy to
conflate: the fleet doc's *no router component* applies to A2A traffic between
gateways within one release. This router is webhook ingress fanning out across
releases. Caller-side variant selection survives unchanged.

## Order of work

Each phase is independently useful, and no phase is a prerequisite for
abandoning the next one.

0. **Fleet step 1, unchanged.** Generalize the chart to a gateways map, ship
   with only `main`. Destructive on purpose. Do it before anything below exists
   to be lost. This phase belongs to the other document; it appears here only
   because its position in the order is the answer to the sequencing question.

1. **Capture.** Enable `webhooks` and `workboard` on `main`. One route per
   source -- start with a single source, and prefer a tracker-shaped one, since
   it is the shape that can still be shadowed in phase 2. Router in
   pass-through mode, minting trace ids. Every event becomes a card. No
   sandbox, no agent involvement, no automation.

   Then live in it for a month. **The deliverable of this phase is knowing what
   the event distribution actually is** -- which types recur, which are
   one-offs, which are reducible to a glanceable artifact. Every downstream
   decision depends on that and none of it can be guessed in advance. This is
   also the phase that fails if the queue is not genuinely used, and it is
   better to discover that here than after building five more.

2. **Sandbox.** Second release, real-reads/fake-writes credentials, default-deny
   NetworkPolicy, separate PVCs. Router begins duplicating at 100%. Sandbox
   emits a proposal artifact per event, attached to the live card by trace id.
   `could-not-reach` wired as a first-class outcome from the start.

3. **Labels and archive.** The five outcomes, captured as a card action. The
   archive holds payload, trace id, proposal and label -- enough to replay
   against. Nothing consumes labels yet; this phase is about the record being
   complete and uniform before anything depends on it.

4. **Replay.** Run a candidate handler over the whole archive and report
   agreement. No deployment involved. This is the phase that makes the rest
   tractable, and it is worth building well.

5. **First promotion.** Pick the event type with the strongest record, write
   the deterministic handler, prove it by replay, then give those cards an
   `automation` block. Keep shadowing the type. Rollback is deleting the rule.

6. **Variants.** Now do fleet steps 2-5 and compare two agent specs on a type
   that resisted deterministic handling. Expect this to be slow, and treat a
   result inside six months with suspicion.

## Deliberately not doing

- **No custom queue or swimlane UI.** `workboard` is it. Building a second
  inbox beside a tracker already in daily use is the most reliable way to
  ensure neither gets used.
- **No mirrored conversation source.** That context cannot be mirrored; real
  reads with no write path is the honest substitute. Revisit only if a second
  person's events ever enter the system.
- **No statistical model in v1.** Counts by type and outcome. See the
  arithmetic -- a model over 19 points per arm is a decoration that invites
  false confidence.
- **No agent variants before deterministic promotion.** Variants need the
  fleet, need both arms, and pay off slowest. Deterministic rules are provable
  offline against history.
- **No sampling below 100%.** If the sandbox is safe, less data is pure loss;
  if it is not safe, sampling is not the fix.
- **No promotion of an event type out of shadow.** Automated types keep being
  shadowed, or staleness becomes undetectable.
- **No second user.** The credential model is built for one and says so.

## To verify before building

Every finding in [What the source actually says](#what-the-source-actually-says)
is a source read against the image, not a runtime check. The ones with teeth:

1. **`workboard` runs under our config at all.** It is `enabledByDefault:
   false`, needs a `plugins.allow` slot, and declares
   `doctorContract.stateMigrations` -- so it expects to migrate state on the
   PVC. Confirm it starts and creates a board before designing around its tools.
2. **Where `workboard`'s sqlite actually lives.** The whole phase-0 ordering
   argument rests on it being on the openclaw PVC. It almost certainly is, but
   the argument is load-bearing enough to check rather than assume.
3. **Whether the dashboard is reachable.** The plugin declares dashboard data
   bindings and action verbs; whether our deployment exposes a dashboard at all
   is a separate question, and the answer decides whether the queue has a UI or
   is CLI-and-tools only. That in turn decides whether phase 1 is usable enough
   to live in for a month, which is the phase's entire test.
4. **`webhooks` route semantics.** A route maps to a `sessionKey` and binds to
   "TaskFlows" -- confirm what that actually dispatches, and that an inbound
   event can create a `workboard` card without an agent turn in between. If it
   cannot, phase 1 needs a small handler and that is worth knowing early.
5. **Whether the `secret` SecretRef resolves.** The `a2a` token turned out to
   be a literal despite the docs; this plugin declares a proper
   `configContracts.secretInputs` path, which is the opposite signal. Cheap to
   confirm, and it decides whether `render.sh` needs another substitution.

## Re-deriving the findings

```sh
cid=$(docker create asi/openclaw:2026.8.1)
docker cp "$cid":/app/extensions/workboard ./workboard
docker cp "$cid":/app/extensions/webhooks  ./webhooks
docker rm "$cid"
```

`workboard/src` is ~50 files; `store.ts`, `store-automation.ts`,
`dispatcher.ts` and `sqlite-store.ts` carry the parts this design leans on.
`webhooks` is four files.
