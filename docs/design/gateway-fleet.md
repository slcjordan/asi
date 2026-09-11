# Gateway fleet

Turning the single openclaw gateway into a fleet: a second gateway wired in over
A2A, a chart that makes the next one cheap, and A/B variants without a router in
the middle.

Written against openclaw `2026.8.1` and the live `asi-dev` release on
`k3d-halo-dev`, 2026-09-08.

**Status, 2026-09-11: built, deployed, and amended.** All five steps under
[Order of work](#order-of-work) are in the chart and running on `asi-dev`. Two
decisions in this document were overturned during that first deploy, and the
sections below have been corrected rather than left as written:

- **Calls are fire-and-forget, not blocking.** The blocking convention put
  correlation work on `main`; see [Calling convention](#calling-convention).
- **The poets are on IRC**, posting to `#poetry`, because an async call needs a
  return path and `main` is no longer carrying one.

Two findings from the deploy that no amount of reading would have produced are
recorded in [What the first deploy changed](#what-the-first-deploy-changed).

## The shape of it

Today the chart deploys one openclaw gateway, one ergo, one collector. This adds
a second gateway, reachable from the first over the bundled A2A channel plugin,
and generalizes the chart so a third costs one values entry and one directory.

```
 ┌──────────┐  #asi   ┌─────────────┐       A2A       ┌──────────────────┐
 │          │<───────>│ main        │────────────────>│ poet-a           │
 │ ergo     │         │ agent: main │ fire-and-forget │ agent: poet      │
 │ irc      │         │ :18789      │───────────┐     └──────────────────┘
 │ 6667/97  │         └─────────────┘           │     ┌──────────────────┐
 │          │                                   └────>│ poet-b           │
 │          │                                         │ agent: poet      │
 │          │<──── #poetry ───────────────────────────│ variant · :18789 │
 └──────────┘      (poems, posted by the poets)       └──────────────────┘

        every gateway ──> otel-collector · otlp/http 4318
```

The caller picks the variant. There is no proxy between `main` and the second
gateway -- that is the central decision, and [A/B without a
router](#ab-without-a-router) is why.

### Why a poet

The second gateway is a deliberate placeholder. Its agent takes a subject and
writes a poem: one model turn, one tool, no side effects, no credentials of its
own beyond the A2A bearer and the shared IRC PASS. The deliverable here is the *fleet* -- the chart
generalization, the A2A edge, per-gateway telemetry, caller-side variant
selection -- and a placeholder keeps the agent from competing with that for
attention or for debugging time. When something fails end to end it is the
plumbing, because there is nothing else it could be.

It also happens to be a good A/B subject. Two variants that differ by model or
prompt produce visibly different poems on the same input, so [A/B without a
router](#ab-without-a-router) can be evaluated by reading the output rather than
by instrumenting it.

What it does not exercise is long-running work, or in fact *any* of the task
machinery: calls are fire-and-forget, so `GetTask`, the task store's limits and
the FIFO-per-context hazard all sit unused. See [Short jobs, long
jobs](#short-jobs-long-jobs) for what that leaves untested for whatever real
agent takes this slot later.

## What the source actually says

Four findings from reading the bundled plugin in the running image. Each one
moved the design, and each is worth re-checking on an openclaw upgrade, because
none of them is guaranteed by the documentation.

### Outbound A2A discards the reply

`a2a/src/outbound.ts:71,124`

`sendA2aChannelText` hardcodes `configuration: { returnImmediately: true }` and
returns only the task id. On the receiving side the agent's answer goes into an
in-memory task store, never back to the caller. So `message -> a2a:poet` delivers
the request and throws the answer away. Anything that needs a result calls
`/a2a/v1` itself.

### Peer tokens are literals, not SecretRefs

`a2a/src/config-schema.ts:12`, `a2a/src/http.ts:67`

The channel doc shows `token: "${A2A_HERMES_TOKEN}"`, but `token` is a plain
`z.string()` compared as a digest against the presented bearer, and `a2a` ships
no `secret-contract-api.ts` the way telegram does -- so it appears nowhere in
openclaw's SecretRef credential surface. The chart has to render the literal
value.

**Unverified at runtime.** The throwaway-container test was cut short, so this
rests on the code read alone. Worth confirming before relying on it.

### Tasks are per-process and per-peer

`a2a/src/task-store.ts:4-5,53-59`

`A2aTaskStore` lives in the gateway process; terminal tasks are pruned at 24h or
500 entries, and `stop()` clears everything. A pod roll loses the running job
*and* the handle, and the subsequent poll returns `-32001 Task not found` --
indistinguishable from expired or wrong-replica. `get(taskId, ownerPeer)` also
scopes tasks to the peer that created them.

### Replies are matched FIFO per context, not per task

`a2a/src/task-store.ts:69-102`, `a2a/src/inbound.ts:109`

`completeNext(contextId, ...)` attaches the result to the *oldest pending task in
that context*. Two jobs in flight on one `contextId` can have their answers
swapped onto each other's task ids. One context per concurrent task.

### Things that are simply fine

- **No image change.** `a2a` is bundled at `/app/extensions/a2a` -- confirmed
  present in the running pod -- so it needs only a slot in `plugins.allow` and an
  enabled entry, exactly like `diagnostics-otel`. No npm staging, no
  managed-root trust dance.
- **No gateway token involved.** The three routes register with `auth: "plugin"`,
  so per-peer bearers are the whole auth story. Confirmed live:
  `/.well-known/agent-card.json` 404s until the channel starts.
- **Cluster-internal URLs pass the SSRF guard.**
  `ssrfPolicyFromHttpBaseUrlAllowedOrigin` promotes the peer's own hostname into
  `allowedHostnames`, which skips the private-network check.
- **Multi-gateway isolation is free here.** openclaw's warnings about profiles,
  state directories and derived ports are about several gateways on one host;
  separate pods with separate PVCs satisfy all of it by construction.
- **`curl` is in the image.** Verified -- which is all the calling convention
  needs, since the poet agent runs no tools of its own.

## Chart shape

One flat map. A gateway is a values entry plus a directory of agent definitions;
everything else derives.

```yaml
openclaw:            # unchanged: shared defaults -- image, plugins, otel, persistence, provider

gateways:
  main:
    irc: { enabled: true }
    a2a:
      calls: [poet-a, poet-b]   # targets it may address; mints tokens both directions
  poet-a:
    irc:                        # on IRC to *deliver*, on its own channel
      enabled: true
      nick: poet-a
      channels: ["#poetry"]
      groupDefaults: { requireMention: true }
    messages: { visibleReplies: message_tool }
  poet-b:
    irc: { enabled: true, nick: poet-b, channels: ["#poetry"], groupDefaults: { requireMention: true } }
    messages: { visibleReplies: message_tool }
    # variant: differs by prompt only -- same agent id, so cards and bindings match
```

**Templates.** The four `openclaw-*.yaml` files stay and become a `range` over
`.Values.gateways`, each driven by one merged per-gateway context.
`asi.gateway.fullname` resolves to `<fullname>-<key>`, so `main` becomes
`asi-main` and the live `asi-openclaw` StatefulSet is renamed -- see [Blast
radius](#blast-radius).

**Agents.** Move to `agents/<gateway>/<agentId>/agent.yaml`, glob
`agents/*/*/agent.yaml`. Discovery stays directory-driven and the owning gateway
becomes visible in the path. Agent ids need only be unique within a gateway, so
both poet variants keep the id `poet`.

```
charts/asi/agents/<gateway>/<agentId>/
    agent.yaml     # config: agents.entries.<agentId>, plus routing bindings
    AGENTS.md      # the definition -- injected into the system prompt
    SOUL.md  IDENTITY.md  USER.md  BOOTSTRAP.md
```

Four hops from the repo to the prompt, each one per gateway:

| Hop | Where |
| --- | --- |
| ConfigMap | `asi-<gateway>-agents`, keys `<agentId>--<file>` |
| Init container mount | `/agents/<agentId>/<file>`, via the volume's `items` |
| Workspace after `render.sh` | `/home/node/.openclaw/workspace/<agentId>/`, always -- see below |
| Physically | that gateway's own PVC, `data-asi-<gateway>-0`, under subPath `openclaw/workspace` |

The gateway moves out of the ConfigMap *key* and into its *name*, because there
is now one ConfigMap per gateway.

**`$multi` goes away entirely.** It is currently computed globally -- `gt (len
$ids) 1` over every agent the glob finds (`_helpers.tpl:168`) -- and three things
branch on it: the workspace path (`:186`), whether a missing `bindings` entry is
a render error (`:197`), and `agents.ownership: "explicit"`
(`openclaw-configmap.yaml:88`).

Left global it is actively wrong: adding `poet-a` would flip `main`'s value and
move `main`'s workspace out from under it, which is the hazard
`agents/README.md` warns about, triggered by a change to a *different* gateway.
Re-scoping it per gateway fixes that, but keeps three conditionals whose
correctness depends on an agent count staying in step with a directory layout
across a fleet. Delete the flag instead, and take the fleet branch
unconditionally:

- **Workspace is always `<root>/<agentId>`.** No agent's path depends on how
  many others exist, so nothing moves when a gateway or an agent is added, and
  the `entry.workspace` the chart renders agrees with the path the init
  container seeds by construction rather than by two ternaries matching.
- **Every agent needs `bindings`.** The fail-closed check loses its `and $multi`
  and applies always. `agents/main/agent.yaml` carries `bindings: []` today and
  needs a real entry -- the `#asi` example already commented in that file. Note
  the check only tests that the list is non-empty; it cannot tell whether the
  bindings cover every channel the gateway joins. That gap is unchanged either
  way.
- **`agents.ownership: "explicit"` is always set.** This is the one with
  behavioural teeth. It opts every gateway out of openclaw's sole-agent
  fallback, so routing is binding-driven everywhere and an uncovered surface
  goes quiet rather than defaulting to the only agent there is. Coherent with
  the rule above, but it is a real change to how `main` routes today, so it is
  the thing to verify on the first deploy rather than assume.

One assumption `$multi` never guarded comes along for the ride.
`otel.resource.workspace.path` (`values.yaml:344`) is hardcoded to the
sole-agent root, so today a second agent would leave the provenance fingerprint
covering the *parent* of every workspace instead of the agent's own -- silently,
with no render error. Deriving it per agent falls out of the same change.

The cost is a one-time reset: `main`'s existing working files stay at
`/workspace` while its workspace becomes `/workspace/main`. There is no
production, and the namespace and its PVCs are expendable -- which is precisely
what makes deleting the flag cheaper than scoping it.

**ConfigMaps.** One per gateway rather than one shared, so `checksum/agents` is
scoped: editing the poet persona rolls the poet pod and leaves `main` alone.
That is a straight improvement on today's single checksum, and it is what makes
prompt-tuning one A/B variant cheap -- editing `poet-b`'s `AGENTS.md` does not
disturb `poet-a` or the contexts already pinned to it.

**Secrets.** Keys per edge, named for what the caller *addresses*:
`a2a-token-<target>-from-<caller>`. `asi.secrets` builds its `$lengths` dict by
ranging the edge list instead of today's static three. Also
`openclaw-gateway-token-<gateway>` per gateway. Note the schema requires `token`
even on a purely outbound peer, so every edge mints both directions whether or
not both are used.

**Guards.** Mirror the existing `diagnostics-otel` check: if a gateway declares
A2A peers and `plugins.allow` omits `a2a`, refuse to render. Same silent-nothing
failure mode, same fix -- fail at `make deploy`, not in production silence.

**Keep the token out of the ConfigMap.** Since the token has to be a literal,
have `render.sh` substitute it from the mounted Secret at boot rather than baking
it into the ConfigMap's `openclaw.json`. The init container already does exactly
this for the IRC PASS. One `sed`, and `kubectl get configmap` stops being a
credential disclosure.

## The A2A edge

What the chart renders on each side of one edge.

Callee -- `poet-a`:

```json
{
  "channels": { "a2a": {
    "enabled": true,
    "advertisedUrl": "http://asi-poet-a:18789",
    "exposeAgents": ["poet"],
    "peers": { "main": { "token": "<inbound>" } }
  }},
  "plugins": { "allow": ["...", "a2a"], "entries": { "a2a": { "enabled": true } } }
}
```

Caller -- `main`:

```json
"peers": {
  "poet-a": {
    "token":         "<its own inbound token for poet-a -> main>",
    "url":           "http://asi-poet-a:18789/a2a/v1",
    "outboundToken": "<poet-a's inbound token for main>"
  },
  "poet-b": { "...": "..." }
}
```

Each gateway's agent needs a `bindings` entry covering the channels it serves --
`{match: {channel: "a2a", accountId: "*"}}` for a poet gateway. There is no
sole-agent fallback to lean on once `ownership` is always explicit, and the
chart's fail-closed check demands one regardless of how many agents the gateway
runs.

## Calling convention

The main agent makes the A2A call itself, as an HTTP client, bypassing the
plugin's outbound path and its discarded reply. Instructions live in
`agents/main/main/AGENTS.md` -- already copied into the workspace by the chart
-- and graduate to a `SKILL.md` when they outgrow that.

**The call is fire-and-forget.** `main` sends `returnImmediately`, gets a task
id, discards it, and moves on. It does not wait, does not poll, and never sees
the poem.

```sh
eval "$(/var/run/asi/bin/pick-poet-gateway "$CTX")"   # sets PEER, URL, TOKEN_FILE

curl -sS "$URL" \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"SendMessage","params":{
        "configuration":{"returnImmediately":true},
        "message":{"messageId":"'"$(cat /proc/sys/kernel/random/uuid)"'",
        "role":"ROLE_USER","contextId":"'"$CTX"'",
        "parts":[{"text":"for '"$NICK"': Rondeau about a rebuilt cluster."}]}}}'
```

The token is read from a file on tmpfs, the same handling the IRC PASS gets, so
it never enters the model's context.

### Why not blocking

An earlier draft of this plan had `main` block on the call and relay the answer
into `#asi`, with `GetTask` as the fallback for long jobs. That is simpler on
the wire and it was wrong for this fleet, for a reason that only shows up when
you ask who holds the state:

**Blocking makes `main` the correlation point.** Every request occupies its
turn for the length of someone else's model call; concurrent requests have to
be kept apart by hand under a FIFO-per-context reply rule that swaps answers if
you get it wrong; and the whole conversation in `#asi` serializes behind
whichever poem is in flight. Fire-and-forget moves all of that out of the
top-level gateway, which is the gateway you least want holding it.

### The return path is IRC, not A2A

Async has one hard consequence: **the answer cannot come back on the call**, so
something else has to deliver it. Three candidates, and only one of them
actually removes work from `main`:

| Path | Who correlates | Verdict |
| --- | --- | --- |
| **Poet posts to `#poetry` itself** | nobody | Chosen. |
| Poet calls `main` back over A2A | `main` | Inbound A2A lands in a *separate isolated session*, detached from the conversation that asked, so `main` has to stitch it back -- more correlation than blocking, not less. |
| `main` fires and polls `GetTask` | `main` | Async on the wire only. Also inherits the task store's limits. |

So the poets are on IRC after all, which this plan had deferred. They are on a
**different channel** from `main`, which is what keeps the bot-loop hazard away
from `#asi` -- see [Blast radius](#blast-radius) for the trap itself.

Two consequences worth stating, because both contradict the placeholder as
originally scoped:

- **The poet is no longer toolless.** Its source channel is A2A and its
  destination is IRC, and openclaw has no automatic path between the two, so
  it delivers by running `post-poem` -- a script the chart ships in its
  ConfigMap, exactly as `main` gets `pick-poet-gateway`. Not openclaw's
  `message(action="send")`: see [What the first deploy
  changed](#what-the-first-deploy-changed) for why that does not survive
  contact with the model.
- **Nothing reports failure.** A fire-and-forget request the poet never
  completes is indistinguishable from one still in progress. There is no
  retry, no dead-letter, and no error path back to `main` or to the person who
  asked. Accepted deliberately: the alternative is the correlation state this
  design exists to avoid. It is also the first thing that stops being
  acceptable if the slot ever takes an agent whose work matters.

### Addressing

`main` prefixes the request text with `for <nick>:`, naming whoever asked, and
the poet echoes that nick when it posts. It is the only thread tying a poem in
`#poetry` back to a person, since the request itself left no trace there.

### Short jobs, long jobs

None of it runs. Calls are fire-and-forget, so `GetTask` is never called, the
task store is never read, and the FIFO-per-context reply hazard never fires --
`main` discards the task id the moment it has it.

That is a lot of carefully-derived machinery sitting unused, and it is worth
being explicit that it is unused rather than quietly leaving the findings above
to imply otherwise. What remains true and would matter again the day something
needs a result back:

- **A blocking call that outruns `replyTimeoutMs`** (120s default, 600s cap)
  returns the still-working task rather than erroring, so one code path covers
  quick and slow.
- **One `contextId` per concurrent task.** `completeNext` attaches a result to
  the oldest pending task in the context, so two in flight on one context can
  have their answers swapped.
- **The task store does not survive a pod roll.** Memory, 24h, 500 entries.
- **`CancelTask` is refused** with `-32004` by design.

The convention `main` actually follows now is thinner: one `contextId` per
conversation, reused across requests so the poet keeps its memory of it, and
one request in flight on it at a time.

### The status log

The durability half of this is gone with the blocking call -- there is no task
to ask about, and the poet has nothing to report progress on. Recorded here for
whatever takes the slot later: a gateway with a persistent workspace can append
progress to a file and answer "how's it going?" from disk, which survives
restarts and outlives the task store.

What remains, and is load-bearing, is the **variant assignment log**. The
caller writes the chosen peer for a context into a file in `main`'s workspace,
not the callee's -- `main` is the side that has to read it before it knows
which gateway to address. One append-only line per context, `<contextId>
<peer>`, and it is what lets the selection rule under [A/B without a
router](#ab-without-a-router) stop being a hash the caller has to keep agreeing
with.

## A/B without a router

Stickiness is not really a `GetTask` problem -- it is a session problem. The
session for `(peer, contextId)` lives in one pod's sqlite on its own PVC, so a
context that lands on a different variant loses its history even when the task
store is irrelevant. A stateless splitter in the middle of a stateful protocol is
the wrong shape.

So the caller picks. Two named peers, one deterministic choice per context, and
it stays there for the life of that context. Exact stickiness, no task-id map, no
new deployment -- and it degrades better than a proxy would, since a router's
in-memory map would go stale at exactly the moment the backend's tasks did.

### Selecting a variant

Rendezvous hashing (`argmax_i H(ctx || node_i)`), not consistent hashing.
Consistent hashing earns its keep with many nodes and needs virtual nodes to
balance at all; rendezvous gets the same minimal-disruption property with no
ring, perfect balance at two nodes, and a clean extension to weights via the log
method (`score = -w / ln(u)`).

```sh
best= bestscore=
for g in poet-a poet-b; do
  s=$(printf '%s|%s' "$ctx" "$g" | sha256sum | cut -c1-16)
  if [ -z "$bestscore" ] || [ "$s" \> "$bestscore" ]; then best=$g bestscore=$s; fi
done
```

Lexicographic comparison is safe on equal-length lowercase hex.

**The hash choice matters less than recording the result.** Minimal-disruption
properties only pay off if the mapping is recomputed, and it should not be: write
the assignment into `main`'s workspace status log, and an existing context is
pinned by that record rather than by the hash. Adding `poet-c` then cannot move
it, and the hash only ever assigns contexts that have no record yet. Rendezvous
because it is simpler and weight-extensible, not because its rebalancing
guarantees are load-bearing.

Two practical constraints:

- **It has to be a script, not prose.** An LLM asked to send 10% of work to B will
  not produce a calibrated 10%, and cannot compute a hash in its head. Ship a
  `pick-poet-gateway` script in the gateway ConfigMap and have `AGENTS.md` say
  *run this*. That also puts the weights in `values.yaml`, where the chart renders
  them.
- **Weighted rendezvous needs float math**, so the shell version wants `awk`.
  That is the point where ergonomics start arguing for a flag service.

### When to revisit

The natural upgrade is OpenFeature with **flagd** as the provider: k8s-native,
flags from a ConfigMap or CRD, and its `fractional` operator does exactly this
job -- deterministic weighted bucketing keyed by a targeting value, which would
be the `contextId`. It buys weight changes without rolling the main pod, targeting
rules beyond a percentage (*long-form requests go to B*), and a kill switch that needs no
`helm upgrade`.

It is not a hashing upgrade -- mod-bucketing on a murmur hash has the same
remap weakness as `sha256 mod 100` -- it is a control-plane upgrade, and it costs
a deployment plus an HTTP call before every A2A call. At two variants on a dev
cluster, `values.yaml` plus twenty lines of shell is less machinery, and
version-controlled weights suit a repo where the chart is already the source of
truth for everything else. Adopt it when one of these becomes true: more than two
or three variants, weights that must change without a deploy, real targeting
rules, or a second caller needing the same flag.

Measurability is not a reason to adopt it. Since `service.name` is derived per
gateway, spans are already separable by variant without flag-evaluation events on
them.

| Approach | Stickiness | Verdict |
| --- | --- | --- |
| **Caller-side selection** | Exact, by construction | Chosen. Weights live in main's config, so changing the split rolls that pod. |
| A2A-aware proxy | Hash `contextId`, map `taskId -> backend` | ~150 lines of Go, no SDK needed -- everything is in the envelope and the response. Worth writing only for external clients that cannot be taught to choose. |
| Envoy with a caller-set header | `ring_hash` on `x-a2a-context` | Works, but if the caller is ours anyway, it can just pick the backend. |
| Two Deployments, one Service | None -- per-connection random | Avoid. This is precisely the broken case. |

### On forward compatibility

A2A does no NAT traversal; it is HTTP JSON-RPC to a URL the caller must already
reach, and `advertisedUrl` exists only so a proxy can front it. openclaw's
answers to an unroutable peer sit below A2A -- Tailscale Serve for a stable HTTPS
origin, or Reef's relay for agents owned by different people, which is a
different channel and a different trust model. If the second gateway ever leaves
the cluster, the peer URL changes and nothing else does.

There is also no A2A client library to adopt: no `@a2a-js/*` in the image, and
the plugin's own client is 130 lines of `fetch`.

## Blast radius

- **Makefile.** `restart-openclaw`, `logs-openclaw`, `gateway` and the
  `provenance*` targets all name `$(RELEASE)-openclaw` and the single token key.
  They become `NAME=`-parameterized.
- **Telemetry.** `otel.serviceName` and `otel.resource.agent` are single-gateway
  assumptions -- derive both per gateway, or every span from both pods claims
  `openclaw-gateway` / `main`. `otel.resource.workspace.path` is a single-*agent*
  assumption in the same shape; see [Chart shape](#chart-shape). The collector
  stays shared.
- **Naming and volumes.** `main` renders as `asi-main`, renaming the live
  `asi-openclaw` StatefulSet and stranding `data-asi-openclaw-0` -- the agent
  workspace, the session sqlite and the provenance store. Accepted, for the same
  reason the workspace move is: there is no production here, the cluster is
  rebuildable, and anything wanted from the old volume is recoverable through
  `make provenance-show` before it goes. A `nameSuffix` key that pinned the old
  name would avoid the rename and is not worth carrying.
- **Rotation.** Every pod carries `checksum/secrets` over the whole resolved map,
  so rotating any A2A token rolls the fleet. Consistent with how rotation already
  behaves.
- **IRC, if the poet gateway ever joins.** IRC has no `allowBots`, so openclaw's
  bot-loop protection cannot see a second instance as a bot. With today's
  `allowFrom: ["*"]` and `requireMention: false`, two bots in `#asi` will answer
  each other indefinitely -- and two *poets* in a channel is the version of that
  loop that produces the most output before anyone notices. Not a problem in this
  plan, since the poet gateway is A2A-only, but it is the trap to remember if
  that changes.

## Order of work

Each step lands deployable. The fleet refactor comes before the second gateway so
the new gateway is never a special case.

1. **Generalize the chart to a gateways map.** Range the four templates, move
   agents under `agents/<gateway>/`, split the ConfigMaps, make secret keys
   edge-derived, delete `$multi`, and give `main` a real `bindings` entry. Ship
   with only `main` defined.

   This is deliberately not a no-op: the StatefulSet is renamed and the
   workspace moves, so the old release cannot be upgraded in place. Review
   `helm template` for the intended diff, then delete the namespace and its
   PVCs and deploy clean. The test is behavioural rather than textual -- `main`
   still answers in `#asi`, now routed by an explicit binding with
   `ownership: explicit` and no sole-agent fallback, and its workspace is
   `/home/node/.openclaw/workspace/main` with the persona files in it. Adding
   `poet-a` in step 3 must not move that path.
2. **Add the A2A channel to main.** `plugins.allow`, the enabled entry, the
   render-time guard, and the `render.sh` token substitution -- with no peers
   yet. Confirms the plugin loads and `/.well-known/agent-card.json` answers
   before any second pod exists.
3. **Stand up poet-a.** New values entry, `agents/poet-a/poet/` with the persona,
   IRC off, one edge from `main`. The persona is short by design: take a subject
   (and optionally a form), return a poem, no tools. Verify end to end with a
   blocking `SendMessage` from inside the main pod before any agent is taught
   about it -- a poem in `result.task.artifacts[0].parts[0].text` is the whole
   pass condition, and it is unambiguous in a way a git result would not be.
4. **Teach the main agent to call it.** The curl paragraph in `AGENTS.md`, the
   tmpfs token mount, per-task contexts, and the `GetTask` follow-up. This is the
   step where the poet gateway becomes reachable by conversation rather than by
   hand. Write the polling branch here even though step 3 proved the inline one;
   see [Short jobs, long jobs](#short-jobs-long-jobs) for how to force it to run
   at least once.
5. **Add poet-b and the selection rule.** Copy the gateway entry, vary the model
   or prompt -- a different model, or the same model told to favour a different
   register -- and keep the agent id. The split rule and the assignment log go in
   the skill. Unlike a git variant, this one is worth doing immediately: it is the
   cheapest honest test of caller-side selection, and comparing two variants is
   the one thing the placeholder is genuinely good at.

## Deliberately not doing

- **No router component in the chart.** Dropped in favour of caller-side
  selection; revisit only for external A2A clients.
- **No feature-flag service yet.** flagd is the right shape for runtime weights
  and targeting rules, but not at two variants -- see *When to revisit*.
- **No mutual A2A peering for replies.** The answer would arrive in a separate
  isolated session rather than the conversation that asked, which is worse than
  the curl call it would replace.
- **No custom plugin or MCP wrapper** for the outbound call. `exec` plus `curl`
  covers it; a plugin only earns its keep if the call needs to be unavailable to
  the agent's own shell.
- ~~**No poet gateway on IRC** in this pass.~~ **Overturned.** Fire-and-forget
  needs a return path and IRC is the only one that keeps correlation out of
  `main`. The channel-policy rework came with it: separate channel, and
  `requireMention: true` so the two poets in `#poetry` do not answer each
  other.
- **No tools beyond a shell and `post-poem` in the poet agent.** Delivery
  forced that much on it; nothing else should follow. Every further capability is one to
  re-litigate when the placeholder is replaced, and a second thing to suspect
  when the plumbing misbehaves. No memory, no retrieval, no filesystem work.
- **No promoting the placeholder.** When there is real work for a second gateway
  -- git or otherwise -- it takes the slot as a new gateway key with its own
  agent directory, and the poet stays or goes on its own merits. Growing tools
  onto `poet` to avoid writing a values entry would defeat the point of making
  the entry cheap.

## What the first deploy changed

Two things that reading the source would not have produced, both found by
running it.

### `messages.visibleReplies` has no safe default

Unset, openclaw resolves the delivery contract from the agent harness's
`deliveryDefaults.sourceVisibleReplies`, and only an internal WebChat surface
is guaranteed `automatic`. On A2A it resolved to `message_tool`: the agent's
final text is withheld unless it calls the message tool. A toolless poet then
wrote a correct poem, completed its run, and delivered nothing:

```
[source-reply/private-final] agent produced a long private final reply without
  calling the configured delivery tool (message_tool_only); response kept
  private and not delivered to the source channel
[turn/execution] visible channel turn dispatched with no queued reply payloads:
  channel=a2a ... cause=completed
```

Nothing errored. The run *completed*. The caller's blocking call returned on
time with an empty artifact list, and the only trace was those two lines in the
callee's log. The chart now writes the key explicitly for every gateway --
`automatic` for `main`, `message_tool` for the poets -- because a value that
varies by harness and by surface is precisely the silent-nothing failure this
chart refuses everywhere else.

### Delivery is a shell command, not openclaw's reply path

Cross-channel delivery -- answering into a channel that is not the turn's
source channel -- goes through `message(action="send")`, and the model would
not call it. The poem was written, the turn completed successfully, and the
text was discarded, three times running:

```
[turn/execution] visible channel turn dispatched with no queued reply payloads:
  channel=a2a sessionKey=agent:poet:a2a:...:irc-channel-asi cause=completed
```

This is a documented weakness rather than a misconfiguration. openclaw's own
docs: *"Some weaker models can answer final text but fail to understand that
source-visible output must be sent with `message(action=send)`… For models
that repeatedly strand replies, use `automatic`."* But `automatic` delivers to
the **source** channel, which here is A2A -- so the one reliable path could not
reach `#poetry`, and the one path that could reach `#poetry` was the unreliable
one. `openclaw doctor` reported no mismatch; the tool was available and simply
unused.

Three escalating prompt revisions did not move it, including an unmissable
instruction at the top of the file. What fixed it, first try, was giving the
poet a **`post-poem` script** and telling it to run that instead.

The lesson generalises past this fleet: **a delivery tool competes with the
model's belief that its final text is its answer; an ordinary action tool does
not.** Running a command is a thing models do without being reminded. Framing
the same work as "reply, but through this tool" is the framing they drop.

Three things fell out of the change beyond reliability:

- **The nick is right.** openclaw opens a fresh IRC connection per
  cross-channel send, which collided with its own persistent connection and
  posted as `poet-a_`. Verified across three configurations -- not joined,
  joined and listening, joined and not listening -- so it was openclaw
  behaviour, not a chart setting. With no openclaw IRC channel on the poets at
  all, nothing holds the nick and `post-poem` takes `poet-a` cleanly.
- **The bot loop is structural, not policed.** The poets are never *in*
  `#poetry` between posts, so there is no inbound traffic for them to answer
  and no `requireMention` rule to get right.
- **`visibleReplies` stops mattering on the poets.** Their final text goes
  nowhere either way; the script is the delivery.

Still one IRC connection per poem, against ergo's per-IP connection throttle.
Fine at conversational rates, unmeasured above them -- but now it is our code,
so it is fixable without waiting on upstream.

### Traces were never broken; metrics were drowning them

The collector's stdout is the whole trace store, and a container log is a
fixed-size window. Metrics export every `flushIntervalMs` regardless of
activity; spans only when an agent runs. At `detailed` a metrics batch is
~3,000 lines, so the retained window collapsed to about three minutes and
`make traces` reliably found nothing.

Two wrong conclusions were reached before the right one, both from reading
absence as evidence: first "traces are not exported" (they were), then "24
trace batches arrived" (those were metric *data points* carrying a
`signal=traces` attribute). What settled it was the collector's own counters,
which are not in the log at all:

```
otelcol_receiver_accepted_spans  592
otelcol_exporter_sent_spans      592
otelcol_exporter_send_failed_spans 0
```

Received, forwarded, printed, and scrolled away. The immediate fix is a second
debug exporter at `basic` for the metrics pipeline. The real fix is that spans
now also go to a **Jaeger release in its own namespace**, so retention stops
being a property of log rotation — separate namespace because `make nuke`
would otherwise take the history with it, and namespace deletion ignores
`helm.sh/resource-policy: keep`. See `deploy/jaeger.values.yaml`.

The lesson cost three wrong conclusions before it landed, and it generalises:
**a debug exporter is a terminal, not a store, and a container log is a window
rather than a record.** Absence in either is not evidence of absence in the
system. The first question about a missing span is whether it was printed and
lost, not whether it was sent — and only the collector's own telemetry can
answer that.

`openclaw.tool.execution` spans were written off in an earlier draft of this
section as non-existent, on exactly that bad reasoning. They had been
exporting the whole time, on every gateway, and were visible in Jaeger within
a minute of it being deployed. `openclaw.exec` spans remain genuinely
unobserved, now including in Jaeger, and remain unexplained.

## Re-deriving the findings

Everything above about A2A came from the plugin source inside the image, not from
the published docs -- which disagree with it in at least one place. To read it
again after an openclaw bump:

```sh
cid=$(docker create asi/openclaw:2026.8.1)
docker cp "$cid":/app/extensions/a2a ./a2a     # ~2900 lines of TypeScript
docker cp "$cid":/app/docs ./openclaw-docs     # channels/a2a.md, gateway/secrets.md
docker rm "$cid"
```

### The one open test

Whether `channels.a2a.peers.*.token` resolves a `${ENV}` template, or is compared
as a literal. The code says literal; the channel doc implies otherwise. Run a
throwaway gateway with a token written as a template, then call `GetTask` with a
bogus id -- it authenticates without dispatching an agent turn, so no model
provider is needed:

```sh
# config: channels.a2a.peers.test.token = "${A2A_TEST_TOKEN}", plugins.allow ["a2a"]
docker run -d --name a2atest -e OPENCLAW_SKIP_ONBOARDING=1 -e A2A_TEST_TOKEN=envsecret123 \
  -v "$PWD"/openclaw.json:/seed/openclaw.json:ro --entrypoint sh asi/openclaw:2026.8.1 \
  -c 'mkdir -p $HOME/.openclaw && cp /seed/openclaw.json $HOME/.openclaw/ && exec node openclaw.mjs gateway'
```

Then POST `{"jsonrpc":"2.0","id":"1","method":"GetTask","params":{"id":"nope"}}`
to `/a2a/v1`, once with `Bearer envsecret123` and once with the literal
`Bearer ${A2A_TEST_TOKEN}`. HTTP 401 means that form did not authenticate;
JSON-RPC `-32001 Task not found` means it did. If the literal wins, the chart
must render the real token -- which is what this plan assumes.
