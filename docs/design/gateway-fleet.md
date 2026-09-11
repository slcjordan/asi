# Gateway fleet

Turning the single openclaw gateway into a fleet: a git gateway wired in over
A2A, a chart that makes the next one cheap, and A/B variants without a router in
the middle.

Written against openclaw `2026.8.1` and the live `asi-dev` release on
`k3d-halo-dev`, 2026-09-08.

## The shape of it

Today the chart deploys one openclaw gateway, one ergo, one collector. This adds
a second gateway that owns git work, reachable from the first over the bundled
A2A channel plugin, and generalizes the chart so a third costs one values entry
and one directory.

```
                                                 ┌──────────────────┐
                                            A2A  │ git-a            │
                                        ┌───────>│ agent: git       │
                                        │        │ :18789           │
 ┌──────────┐        ┌───────────────┐  │        └──────────────────┘
 │ ergo     │<──────>│ main          │──┤
 │ irc      │        │ agent: main   │  │        ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
 │ 6667/97  │        │ :18789        │  │  A2A     git-b
 └──────────┘        └───────────────┘  └ ─ ─ ─ >│ agent: git       │
                             │                     variant · :18789
                             v                   └ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
                     ┌───────────────┐                    │
                     │ otel-collector│<───────────────────┘
                     │ otlp/http 4318│
                     └───────────────┘
```

The caller picks the variant. There is no proxy between `main` and the git
gateways -- that is the central decision, and [A/B without a
router](#ab-without-a-router) is why.

## What the source actually says

Four findings from reading the bundled plugin in the running image. Each one
moved the design, and each is worth re-checking on an openclaw upgrade, because
none of them is guaranteed by the documentation.

### Outbound A2A discards the reply

`a2a/src/outbound.ts:71,124`

`sendA2aChannelText` hardcodes `configuration: { returnImmediately: true }` and
returns only the task id. On the receiving side the agent's answer goes into an
in-memory task store, never back to the caller. So `message -> a2a:git` delivers
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
- **`curl` and `git` are both in the image.** Verified.

## Chart shape

One flat map. A gateway is a values entry plus a directory of agent definitions;
everything else derives.

```yaml
openclaw:            # unchanged: shared defaults -- image, plugins, otel, persistence, provider

gateways:
  main:
    irc: { enabled: true }
    a2a:
      calls: [git-a, git-b]     # targets it may address; mints tokens both directions
  git-a:
    irc: { enabled: false }
    a2a: { calls: [] }
  git-b:
    irc: { enabled: false }
    a2a: { calls: [] }
    # variant: differs by model/prompt only -- same agent id, so cards and bindings match
```

**Templates.** The four `openclaw-*.yaml` files stay and become a `range` over
`.Values.gateways`, each driven by one merged per-gateway context.
`asi.gateway.fullname` resolves to `<fullname>-<key>`, so `main` becomes
`asi-main` and the live `asi-openclaw` StatefulSet is renamed -- see [Blast
radius](#blast-radius).

**Agents.** Move to `agents/<gateway>/<agentId>/agent.yaml`, glob
`agents/*/*/agent.yaml`. Discovery stays directory-driven and the owning gateway
becomes visible in the path. Agent ids need only be unique within a gateway, so
both git variants keep the id `git`.

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

Left global it is actively wrong: adding `git-a` would flip `main`'s value and
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
scoped: editing the git persona rolls the git pod and leaves `main` alone. That
is a straight improvement on today's single checksum.

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

Callee -- `git-a`:

```json
{
  "channels": { "a2a": {
    "enabled": true,
    "advertisedUrl": "http://asi-git-a:18789",
    "exposeAgents": ["git"],
    "peers": { "main": { "token": "<inbound>" } }
  }},
  "plugins": { "allow": ["...", "a2a"], "entries": { "a2a": { "enabled": true } } }
}
```

Caller -- `main`:

```json
"peers": {
  "git-a": {
    "token":         "<its own inbound token for git-a -> main>",
    "url":           "http://asi-git-a:18789/a2a/v1",
    "outboundToken": "<git-a's inbound token for main>"
  },
  "git-b": { "...": "..." }
}
```

Each gateway's agent needs a `bindings` entry covering the channels it serves --
`{match: {channel: "a2a", accountId: "*"}}` for a git gateway. There is no
sole-agent fallback to lean on once `ownership` is always explicit, and the
chart's fail-closed check demands one regardless of how many agents the gateway
runs.

## Calling convention

The main agent makes the A2A call itself, as an HTTP client, bypassing the
plugin's outbound path and its discarded reply. Instructions start as a paragraph
in `agents/main/<id>/AGENTS.md` -- already copied into the workspace by the chart
-- and graduate to a `SKILL.md` when they outgrow that.

```sh
curl -sS "$GIT_GATEWAY/a2a/v1" \
  -H "Authorization: Bearer $(cat /var/run/asi/creds/a2a-git-outbound)" \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":"1","method":"SendMessage","params":{"message":{
        "messageId":"'"$(uuidgen)"'","role":"ROLE_USER","contextId":"'"$CTX"'",
        "parts":[{"text":"Rebase feature/x onto main and report conflicts."}]}}}'
```

The token is read from a file on tmpfs, the same handling the IRC PASS gets, so
it never enters the model's context. The reply arrives at
`result.task.artifacts[0].parts[0].text`.

### Short jobs, long jobs

A blocking call that exceeds `replyTimeoutMs` returns the still-working task
rather than erroring, so one code path covers both cases: the agent gets an
answer inline when the job is quick and a task id when it isn't. Then `GetTask`
polls by id. States run `SUBMITTED -> WORKING -> COMPLETED | FAILED | REJECTED`.
`CancelTask` is refused with `-32004` by design, so there is no abort once a git
job starts.

Conventions this depends on:

- **One `contextId` per concurrent task**, or replies land on the wrong task ids.
  Sequential work on a shared context is fine.
- **Blocking waits cap at 600s** (`replyTimeoutMs`, default 120s). Anything
  longer must be fired with `returnImmediately`.
- **Don't trust the task store past a pod roll.** It is memory, 24h, 500 entries.

### The status log is what makes it robust

For anything that must outlive a pod, don't depend on the task store -- *ask the
agent instead of the task*. The git gateway has a persistent workspace, so it
appends progress to a file there as it works. "How's the rebase going?" becomes
another `SendMessage` on the same `contextId`, answered from disk. That survives
restarts, outlives 24h, and doesn't care which replica handles it. The convention
goes in the git agent's `AGENTS.md` alongside the work instructions.

The same log is where a context's variant assignment is recorded, which is what
lets the selection rule under [A/B without a router](#ab-without-a-router) stop
being a hash the caller has to keep agreeing with.

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
for g in git-a git-b; do
  s=$(printf '%s|%s' "$ctx" "$g" | sha256sum | cut -c1-16)
  if [ -z "$bestscore" ] || [ "$s" \> "$bestscore" ]; then best=$g bestscore=$s; fi
done
```

Lexicographic comparison is safe on equal-length lowercase hex.

**The hash choice matters less than recording the result.** Minimal-disruption
properties only pay off if the mapping is recomputed, and it should not be: write
the assignment into the same workspace status log the calling convention already
uses, and an existing context is pinned by that record rather than by the hash.
Adding `git-c` then cannot move it, and the hash only ever assigns contexts that
have no record yet. Rendezvous because it is simpler and weight-extensible, not
because its rebalancing guarantees are load-bearing.

Two practical constraints:

- **It has to be a script, not prose.** An LLM asked to send 10% of work to B will
  not produce a calibrated 10%, and cannot compute a hash in its head. Ship a
  `pick-git-gateway` script in the gateway ConfigMap and have `AGENTS.md` say
  *run this*. That also puts the weights in `values.yaml`, where the chart renders
  them.
- **Weighted rendezvous needs float math**, so the shell version wants `awk`.
  That is the point where ergonomics start arguing for a flag service.

### When to revisit

The natural upgrade is OpenFeature with **flagd** as the provider: k8s-native,
flags from a ConfigMap or CRD, and its `fractional` operator does exactly this
job -- deterministic weighted bucketing keyed by a targeting value, which would
be the `contextId`. It buys weight changes without rolling the main pod, targeting
rules beyond a percentage (*infra repos go to B*), and a kill switch that needs no
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
different channel and a different trust model. If the git gateway ever leaves the
cluster, the peer URL changes and nothing else does.

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
- **IRC, if the git gateway ever joins.** IRC has no `allowBots`, so openclaw's
  bot-loop protection cannot see a second instance as a bot. With today's
  `allowFrom: ["*"]` and `requireMention: false`, two bots in `#asi` will answer
  each other indefinitely. Not a problem in this plan -- the git gateway is
  A2A-only -- but it is the trap to remember if that changes.

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
   `git-a` in step 3 must not move that path.
2. **Add the A2A channel to main.** `plugins.allow`, the enabled entry, the
   render-time guard, and the `render.sh` token substitution -- with no peers
   yet. Confirms the plugin loads and `/.well-known/agent-card.json` answers
   before any second pod exists.
3. **Stand up git-a.** New values entry, `agents/git-a/git/` with the persona and
   the status-log convention, IRC off, one edge from `main`. Verify end to end
   with a blocking `SendMessage` from inside the main pod before any agent is
   taught about it.
4. **Teach the main agent to call it.** The curl paragraph in `AGENTS.md`, the
   tmpfs token mount, per-task contexts, and the `GetTask` follow-up. This is the
   step where the git gateway becomes reachable by conversation rather than by
   hand.
5. **Add git-b and the selection rule.** Copy the gateway entry, vary the model or
   prompt, keep the agent id. The split rule goes in the skill. Only worth doing
   once there is a real variant to compare.

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
- **No git gateway on IRC** in this pass. It is a good complement for long jobs,
  but it needs the channel-policy rework above first.

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
