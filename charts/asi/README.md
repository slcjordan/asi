# asi

An IRC network you own, with an assistant sitting on it: [ergo](https://github.com/ergochat/ergo)
as the ircd and a fleet of [openclaw](https://docs.openclaw.ai) gateways
attached to it — one on IRC, and others it reaches over A2A.

Everything is driven from the repository root `Makefile`, which reads
`KUBE_CONTEXT` and `KUBE_NAMESPACE` from the selected `envs/*.mk`:

```
make env-dev        # select an environment
make image          # build the openclaw image and load it into the cluster
make deploy         # install or upgrade
make gateways       # which gateways this chart deploys
make poem           # end-to-end test of the A2A edge (dispatch, then watch #poetry)
make poetry         # tail #poetry
make jaeger         # trace UI on localhost:16686
make secrets-rotate # re-derive credentials and roll every workload
make traces         # exported spans, grouped by trace id
make help           # everything else
```

Targets that act on one gateway take `GATEWAY=<name>` and default to `main`:
`make logs-gateway`, `make restart-gateway`, `make gateway`, `make provenance`.

`make image` is a prerequisite of the first `make deploy`, not a step of it —
it is slow, it needs a network, and it only has to run again when the openclaw
version or the plugin changes. Deploying without it leaves the pod in
`ImagePullBackOff`, because the image it wants exists in no registry.

## The openclaw image

ergo runs upstream's image unmodified. openclaw does not: it runs
`images/openclaw/Dockerfile`, which is upstream plus the IRC channel plugin.

IRC is not built into openclaw — it is an external package, `@openclaw/irc`,
that `openclaw plugins install` fetches from npm at *runtime* and unpacks under
`~/.openclaw/npm/projects/`. Both halves of that are a problem here. That
directory is the PVC, so an install baked into the image would be masked the
moment the volume mounts over it; and doing the install at boot instead would
put an npm fetch on the startup path of every pod with a cold volume.

The obvious dodge — install anywhere convenient in the image and name it in
`plugins.load.paths` — does not work, and fails in a way worth writing down
because it looks like it works. openclaw grades a plugin by where it was loaded
from. A directory named in `load.paths` loads with origin `"config"`, and an
untrusted plugin is refused the channel ingress queue, so the channel starts
and immediately exits with `openChannelIngressQueue is only available for
trusted plugins`, then retries on a backoff forever. The gateway itself reports
`ready` and `2 plugins: irc, memory-core` throughout, and `plugins list` shows
the plugin `enabled` — nothing looks wrong until you notice the bot never
joins. Only openclaw's managed root yields origin `"global"`, which is what the
channel needs, and that root is on the volume.

So the Dockerfile runs the installer at build time against a throwaway `HOME`
and stages the whole resulting tree at `/opt/openclaw/npm` — image-owned,
outside the volume — and the init container copies it to `~/.openclaw/npm` on
the volume at boot. No network is involved at runtime. The tree survives the
move because the plugin carries its bundled `zod` and its `openclaw` peer
dependency is an absolute symlink to `/app`, not a path relative to the `HOME`
it was installed under.

The copy replaces rather than merges, on the same reasoning as `openclaw.json`:
the image is the source of truth, so a version bump takes effect and the
project directory of a superseded version does not linger beside the new one.

Being on disk is still not enough on its own — `plugins.allow` is an exclusive
allowlist and `plugins.entries.irc.enabled` has to be set, both of which the
ConfigMap does. A second baked-in plugin needs all three touched, not just the
image.

`openclaw.image.tag` in `values.yaml` is the upstream openclaw version, and is
the only place it is written down: `make image` reads the repository and tag
back out of the chart to decide what to build and what to call it. The plugin
is pinned to the same version by default (it declares a `peerDependencies`
floor on openclaw, so it cannot lead the image it goes into); override with
`make image IRC_PLUGIN_VERSION=...`.

On a k3d context `make image` side-loads with `k3d image import`, since there
is no registry in the loop; on any other context it falls back to
`docker push`, which assumes `openclaw.image.repository` names somewhere the
cluster can actually pull from.

## The fleet

The chart deploys one openclaw gateway per entry under `gateways` in
`values.yaml`. Today that is three:

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

A gateway is **one values entry plus one directory of agent definitions**.
Names, Services, PVCs, ConfigMaps, A2A peer maps, secret keys and telemetry
identity all derive from those two, so the next gateway costs an entry and a
directory and nothing else. The chart refuses to render if the two disagree in
either direction — a gateway with no agents, or an `agents/<name>/` with no
gateway.

The second gateway is a deliberate placeholder: its agent takes a subject and
writes a poem, with one tool and no side effects. The deliverable is the
fleet, and a placeholder keeps the agent from competing with the plumbing for
debugging attention. See [`docs/design/gateway-fleet.md`](../../docs/design/gateway-fleet.md)
for the reasoning, and for the A2A source findings the chart is built on.

### The A2A edge

`a2a` is bundled in the image at `/app/extensions/a2a`, so like
`diagnostics-otel` it needs only a slot in `plugins.allow` and an enabled entry
— no npm staging and no managed-root trust dance. All three of its routes
register with `auth: "plugin"`, so the per-peer bearers are the entire auth
story and the gateway token is not involved.

Declaring an edge once wires both ends. `gateways.main.a2a.calls: [poet-a]`
gives `main` a peer entry with a URL and an outbound bearer, gives `poet-a` a
matching inbound peer entry, and mints **both** directions of the token —
openclaw's peer schema requires `token` even on a peer that is only ever
called. Keys are named for what the caller addresses:
`a2a-token-<target>-from-<caller>`.

**Peer tokens are literals, not SecretRefs.** `token` is a plain string
compared as a digest against the presented bearer, and the plugin ships no
secret-contract API, so the real value has to be in `openclaw.json`. The
ConfigMap therefore carries `__ASI_SECRET_*__` placeholders and `render.sh`
substitutes them from the Secret mount at boot — the same treatment the IRC
PASS gets, and what keeps `kubectl get configmap` from being a credential
disclosure.

**The plugin's own outbound path discards the reply.** `sendA2aChannelText`
hardcodes `returnImmediately: true` and returns only a task id, so anything
that needs an answer calls `/a2a/v1` itself. That is why `main`'s agent has a
curl paragraph in its `AGENTS.md` and a bearer on tmpfs rather than a
`message -> a2a:poet` binding.

### Calls are fire-and-forget, and the answer comes back over IRC

`main` sends `returnImmediately`, discards the task id, and moves on. It never
waits and never sees the poem. Blocking would make `main` the correlation
point for every request in `#asi` — serialized behind whichever poem is in
flight, under a FIFO-per-context reply rule that swaps answers when you get it
wrong — and keeping that out of the top-level gateway is the whole point.

The consequence is that the answer cannot come back on the call, so the poets
deliver it themselves: they are on IRC, posting to **`#poetry`**. A different
channel from `main`, deliberately — two openclaw instances in one channel
answer each other forever, and `requireMention: true` on `#poetry` is what
stops the two poets doing it to each other.

Two things follow that are worth knowing before reading the poet's config:

- **The poet is not toolless.** Its source channel is A2A and its destination
  is IRC; openclaw has no automatic path between the two, so it runs
  **`post-poem`**, a script the chart ships in its ConfigMap. Deliberately not
  openclaw's `message(action="send")` — see below.
- **Nothing reports failure.** A request the poet never finishes looks exactly
  like one in progress. No retry, no dead-letter, no error path back. Accepted
  on purpose; the alternative is the correlation state this design avoids.

`make poem` dispatches a request and watches `#poetry` for the result, exiting
non-zero if nothing arrives. `make poetry` just tails the channel.

### A/B without a router

`poet-a` and `poet-b` run the same agent id with different personas. There is
no proxy in front of them: the caller picks, with `pick-poet-gateway` (mounted
from the gateway ConfigMap at `/var/run/asi/bin`), and the choice is recorded
in `main`'s workspace so it never has to be recomputed.

Stickiness is the reason. The session for a `(peer, contextId)` lives in one
pod's sqlite on its own PVC, so a context that lands on the other variant loses
its history — a stateless splitter in front of a stateful protocol is the wrong
shape. Two Deployments behind one Service is precisely the broken case, which
is why each gateway's Service selects on `asi.dev/gateway` and not on the
component label alone.

The script does weighted rendezvous hashing (`gateways.<name>.weight`), but the
hashing is not the load-bearing part — the assignment log is. Adding a third
variant cannot move an existing conversation, because the hash only ever
assigns a context that has no record yet.

Variants are separable in telemetry for free: `service.name` is derived per
gateway, so spans arrive as `openclaw-gateway-poet-a` and
`openclaw-gateway-poet-b` with no flag-evaluation events needed on them.

### The task machinery is entirely unused

Because calls are fire-and-forget, `GetTask` is never called, the task store is
never read, and the FIFO-per-context reply hazard never fires — `main` throws
the task id away as soon as it has one. The findings about all three are still
in the design doc because they become live again the moment anything needs a
result back; today they describe machinery nothing touches.

What is live is thinner: **one `contextId` per conversation**, reused across
requests so the poet keeps its memory of it, and one request in flight on it at
a time.

### Two things the first deploy taught us

**`messages.visibleReplies` has no safe default.** Unset, openclaw takes the
delivery contract from the harness, and on A2A that resolved to `message_tool`
— the agent's final text withheld unless it calls the message tool. A toolless
poet wrote a correct poem, completed successfully, and delivered nothing, with
`[source-reply/private-final]` in the log as the only trace. The chart now
writes the key explicitly for every gateway.

**Cross-channel delivery had to become a shell command.** Answering into a
channel that is not the turn's source channel needs `message(action="send")`,
and the model would not call it — poem written, turn `completed`, text
discarded, three times running. That is a documented weakness (*"models can
answer final text but fail to understand that source-visible output must be
sent with `message(action=send)`"*), and the recommended workaround,
`automatic`, delivers to the **source** channel — which is A2A, not `#poetry`.
The reliable path couldn't reach the destination and the path that could wasn't
reliable.

Three prompt revisions didn't move it. Giving the poet a `post-poem` script
and telling it to run that worked first try. **A delivery tool competes with
the model's belief that its final text is its answer; an ordinary action tool
doesn't.** It also fixed the nick — openclaw opened a fresh IRC connection per
cross-channel send and collided with its own persistent one, posting as
`poet-a_`; with no openclaw IRC channel on the poets, `post-poem` takes
`poet-a` cleanly. And it makes the bot loop structural rather than policed:
the poets are never in `#poetry` between posts.

## Agents

Agents are defined in [`agents/`](agents/), one directory per gateway and one
per agent inside it, rendered into that gateway's `agents.entries` and
`bindings` at template time. The inner directory name is the agent id; a
directory counts as an agent if it holds an `agent.yaml`.

```
agents/main/main/
  agent.yaml     # agents.entries.main, plus routing bindings
  SOUL.md        # the definition -- injected into the system prompt
  AGENTS.md  BOOTSTRAP.md  IDENTITY.md  USER.md
```

Agent ids only have to be unique within a gateway, which is what lets both poet
variants keep the id `poet` — their cards and bindings match, so the caller's
choice of gateway is the only difference between them.

The `*.md` files are the agent's behaviour: openclaw injects the workspace's
bootstrap files into the system prompt on every turn. They must be *in the
workspace* to be injected — there is no config key for a system prompt and none
for context files outside it — so an init container copies them in from a
ConfigMap, and `agents.skipBootstrap` is set so openclaw does not generate
competing copies.

Those filenames are chart-owned and rewritten on every boot, which is the same
rule `openclaw.json` and the plugin tree follow. A persona edit reaches the
agent on the next roll, and the pod rolls by itself because the ConfigMap's
checksum sits on the pod template. Anything the agent wrote over one of those
files does not survive a restart; everything else in the workspace is the
agent's own and is never touched.

That checksum is **per gateway** — there is one agents ConfigMap each — so
retuning `poet-b`'s prompt rolls `poet-b` and leaves `main` and `poet-a`
running, which is what makes changing one arm of an A/B cheap.

This also makes the workspace fingerprint in [Telemetry](#the-trace-id-is-the-run-id)
mean something sharper — `openclaw.workspace.tree` becomes a function of what
is committed here, so identical repo content produces an identical hash. The
seeding runs in the `render` init container and the fingerprint in `provenance`,
which runs after it, so the hash describes the definitions the repo just
installed.

**Bindings are mandatory, for every agent on every gateway.**
`agents.ownership: "explicit"` is set fleet-wide, so there is no sole-agent
fallback anywhere: a surface with no matching binding fails closed and the
agent goes quiet. The chart refuses to render without at least one entry — but
it can only check the list is non-empty, not that it covers every channel the
gateway joins. [`agents/README.md`](agents/README.md) has the rest of the
traps.

**Workspaces never move.** Each agent's is `<workspaceRoot>/<agentId>`, always,
with no sole-agent special case, so adding an agent or a gateway cannot move an
existing one's workspace out from under it.

## Telemetry

openclaw exports OpenTelemetry through its bundled `diagnostics-otel` plugin,
and the chart deploys a collector to receive it. On by default; the two
surfaces worth watching are:

| Span | Covers | Notable attributes |
| ---- | ------ | ------------------ |
| `openclaw.tool.execution` | every tool call, plugin-provided ones included | `openclaw.tool.source`, `openclaw.tool.owner`, `openclaw.toolName` |
| `openclaw.exec` | every child process openclaw spawns | `openclaw.exec.target`, `.mode`, `.exit_code`, `.exit_signal`, `.timed_out`, `.command_length` |

Both hang off `openclaw.run` / `openclaw.harness.run` (which carries
`openclaw.harness.plugin`), alongside `openclaw.model.call` and the
message-flow spans.

```
make logs-otel   # the collector's stdout -- this is the trace view
make traces      # spans grouped by trace id
```

The collector is a sink, not a store: it writes what it receives to its own
stdout with the debug exporter and retains nothing. That is deliberate for a
dev cluster with no observability stack. Point `openclaw.otel.endpoint` at a
real backend and set `otelCollector.enabled: false` when the traces need to
outlive the pod.

### The trace id is the run id

**openclaw exports no run id on spans, by design.** Group by trace id instead.
This is worth knowing before you go looking for the attribute: the exporter's
`addRunAttrs()` is handed an event carrying `runId` and writes only provider,
model, channel and trigger, and `openclaw.run_id`/`openclaw.runId` sit in a
`DROPPED_OTEL_ATTRIBUTE_KEYS` denylist that every span passes through on its
way out. Two independent layers, both intentional — alongside session ids,
call ids and message ids.

What you get instead is genuine parentage. Tool and exec spans are children of
the run span and share its trace id, including children that settle *after*
the parent run has ended (a killed child process still lands on the right
trace).

The one gap: when the exporter cannot resolve a parent span it actually
exported, it leaves the span a root rather than naming a span no backend will
receive — so that exec span lands on a trace by itself. It needs the run to
have started while the exporter was running. In this chart a config change
rolls the pod, so the next run is whole; a pod killed mid-run can still orphan
the exec spans already in flight.

This is also why `openclaw.otel.sampleRate` should stay at `1.0`. It samples
*root* spans, and those orphans are roots — the spans you least want thinned
are the ones a lower rate drops first. It is also why neither the chart nor the
collector filters spans: keeping "only exec" would discard the parents that
make an exec span meaningful.

### agent, and recovering what the agent was running

`openclaw.agent` never reaches tool or exec spans — it is only ever set on
skill spans and a handful of metrics — so it is attached as a **resource**
attribute instead, via `OTEL_RESOURCE_ATTRIBUTES`, which lands it on every span
the process exports. `service.version` rides along as the openclaw build,
defaulting to `openclaw.image.tag`.

The openclaw build is rarely the interesting version, though. What defines this
agent is the content of its workspace — `AGENTS.md`, `SOUL.md`, `IDENTITY.md`,
`USER.md`, `BOOTSTRAP.md` — so three more resource attributes fingerprint that:

| Attribute | What it is |
| --------- | ---------- |
| `openclaw.workspace.tree` | git tree hash of the directory. Pure content: identical contents hash identically on any pod, and it covers untracked and uncommitted files. |
| `openclaw.workspace.snapshot` | commit in the provenance store, and the one that actually **recovers** the contents |
| `openclaw.workspace.git_head` / `.git_dirty` | the workspace repo's own HEAD, and whether it has uncommitted changes |

```
make provenance                                   # fingerprint + every snapshot
make provenance-show SNAPSHOT=<sha>               # what was in it
make provenance-show SNAPSHOT=<sha> FILE=SOUL.md  # that file, as it was
make provenance-diff FROM=<sha> TO=<sha>          # what changed
```

**The workspace repo has no commits and no remote.** openclaw runs `git init`
and never commits, so every file is untracked and `git rev-parse HEAD` fails —
`git_head` honestly reports `none`, and the tree hash carries the whole load.
That is also why the snapshot store exists: a bare repo on the PVC, holding one
commit per distinct workspace state on a `provenance` branch. A tree hash
identifies contents; only the store hands them back.

Snapshotting writes nothing to the workspace's own `.git`. It points
`--git-dir` at the separate store while `--work-tree` stays on the workspace,
with a private index, so the agent's repo gains no commits, no objects, and no
index changes — verified, not assumed.

Two things worth knowing before trusting these:

- **They are computed at boot, so they describe the workspace as the pod
  started — not as it was when a given span fired.** Per-span accuracy is not
  available: openclaw exposes no per-run or pre-exec hook to recompute against,
  and the exporter puts nothing workspace-shaped on a span. In practice the
  content is generated once on first bootstrap and then persists on the PVC
  untouched across restarts, which is what makes a boot-time value worth
  anything; an agent that rewrites its own `SOUL.md` mid-run leaves the
  attribute stale until the next restart. A snapshot is only added when the
  tree actually changes, so an unchanged workspace keeps one stable id.
- **The gateway's `args` are overridden to carry the value in.** A pod's
  environment is fixed before its volume is mounted, so a fingerprint that only
  exists once the PVC is there cannot be passed as a plain env var: an init
  container writes it to a tmpfs and a two-line wrapper appends it to
  `OTEL_RESOURCE_ATTRIBUTES` before `exec`ing the gateway. Only `args` is
  replaced, never `command`, so the image's `tini -s --` entrypoint still runs
  and tini is still pid 1 — signal handling has to stay intact, because a
  SIGTERM that does not close the IRC socket cleanly is what leaves the bot
  stuck on `openclaw_`. The cost is that upstream's `CMD`
  (`node openclaw.mjs gateway`) is now written down here too and has to be
  mirrored if it changes upstream. Set
  `openclaw.otel.resource.workspace.enabled: false` to drop the wrapper and the
  three attributes together.

Resource attributes describe the *process*, not the run. That is accurate here
because each gateway pod runs a single agent, and is the thing to revisit if
that ever stops being true.

Both the service name and these attributes are derived **per gateway**:
`service.name` is `<prefix>-<gateway>`, `openclaw.agent` is the id of the one
agent that gateway runs, and the workspace fingerprint covers that agent's own
workspace. Shared, every span in the fleet would claim `openclaw-gateway` and
`main`, and the two poet variants would be indistinguishable in the collector —
which is exactly the comparison the fleet exists to make. The workspace path
was the sharpest of the three: hardcoded, it would have fingerprinted the
*parent* of every workspace the moment a second agent existed, silently and
with no render error. A gateway that grows a second agent still falls back to
the root and inherits that imprecision; there is one set of resource attributes
per process and no honest way to make it describe two workspaces.

### Metrics will bury your spans

The collector prints to its own stdout and that is the entire store, so the
container log *is* the trace view — and it is a fixed-size window. Metrics
arrive every `flushIntervalMs` whether or not anything happened; spans arrive
only when an agent does something. At `detailed`, one metrics batch is around
3,000 lines, so ten seconds of an idle cluster evicts every span from the log.

That is why metrics get their own terse exporter (`otelCollector.metricsVerbosity`,
default `basic`) while spans keep `detailed`. Before the split the retained
window was about three minutes and `make traces` reliably found nothing —
while the collector was receiving and printing spans perfectly well. If you
ever need metric *values*, raise `metricsVerbosity` temporarily and expect
spans to become unreadable while you do.

The collector's own counters settle this question in one command, and are
worth knowing about because the debug exporter tells you nothing:

```
kubectl port-forward deploy/<release>-otel-collector 18888:8888
curl -s localhost:18888/metrics | grep -E "receiver_accepted|exporter_sent"
```

`otelcol_receiver_accepted_spans` versus `otelcol_exporter_sent_spans`
separates "openclaw never sent it" from "the collector dropped it" from "it
was printed and scrolled away".

### Retention: Jaeger

The collector forwards spans to a Jaeger release running in its own namespace,
in addition to printing them. `otelCollector.tracesEndpoint` is the whole
coupling; empty it and the collector goes back to print-only.

```
make jaeger-deploy    # install/upgrade it (upstream chart, own namespace)
make jaeger           # UI on localhost:16686
make jaeger-validate  # render + check the config against the Jaeger binary
```

Jaeger is **deliberately a separate release in a separate namespace**, from
the upstream `jaegertracing/jaeger` chart rather than one of ours. Separate
namespace because `make nuke` deletes this project's namespace and namespace
deletion ignores `helm.sh/resource-policy: keep` — trace history that dies
with the app is barely better than the log window it replaced. Upstream chart
because Jaeger v2 rides the OpenTelemetry Collector and its config format is
still moving.

Storage is **Badger** — an embedded key-value store on a PVC, not a separate
database — with a 72h TTL. Traces don't downsample the way metrics do (a span
is kept whole or dropped), so retention is a straight disk-for-days trade.
Config and reasoning are in [`deploy/jaeger.values.yaml`](../../deploy/jaeger.values.yaml).

**`make jaeger-validate` is worth running before any deploy.** The values file
supplies Jaeger's config as a *complete* override of the image's built-in one,
so a wrong key is a crashlooping pod after deploy rather than a template that
fails to render. The target renders the chart and hands the resulting config to
the real Jaeger binary's `validate`, which rejects unknown keys.

### Tool spans exist; the debug exporter was hiding them

`openclaw.tool.execution` spans are exported, on every gateway, and show up in
Jaeger. They were never visible in the collector's stdout, which led to a
confident and wrong note here that they didn't exist at all.

That was the same mistake as the "traces are broken" one, twice over: reading
absence in a lossy medium as evidence of absence in the system. A debug
exporter is a terminal, and a container log is a window — neither is a source
of truth about what was emitted. `openclaw.exec` spans have genuinely not been
observed even in Jaeger, which is now a real finding rather than a guess,
though still unexplained.

### The plugin is bundled, not installed

`diagnostics-otel` needs a slot in `plugins.allow` and an enabled entry — the
same two gates as the IRC channel — and nothing else. **Do not install it**,
and do not stage it onto the volume the way `@openclaw/irc` is staged. It ships
inside the image at `/app/extensions/diagnostics-otel`, and being bundled is
load-bearing: the gateway hands a plugin the internal diagnostics bus only when
its origin is `"bundled"` (or it is a trusted official install), and that bus is
the exporter's only event source. An npm-installed copy loads, reports
`enabled`, passes `openclaw config validate`, and exports nothing whatsoever.

This is the mirror image of the IRC trap. There, the managed npm root was the
only place a plugin could earn trust; here, moving the plugin into that root
would *cost* it the access it already has.

Leaving `diagnostics-otel` out of `plugins.allow` while `openclaw.otel.enabled`
is true fails the render rather than deploying a pod that exports silence.

## Credentials

Everything lives in one Secret, `<release>-secrets`. All but one are
**generated** by the chart; `provider-api-key` is **supplied** by you. The
distinction is the whole design.

Which keys exist is *derived from the fleet*, not listed — add a gateway or an
A2A edge in `values.yaml` and its credentials are minted with no second edit.
`make secrets-show` prints whatever the current fleet came to:

| Key                                | Origin    | Used by                                                 |
| ---------------------------------- | --------- | ------------------------------------------------------- |
| `irc-server-password`              | generated | shared — ergo's `PASS` gate, each joining gateway's `passwordFile` |
| `irc-oper-password`                | generated | ergo, for `/OPER admin <password>`                      |
| `openclaw-gateway-token-<gateway>` | generated | that gateway's control UI and API — one per gateway, so `make gateway` on one is not a credential for all |
| `a2a-token-<target>-from-<caller>` | generated | the bearer `<caller>` presents when it addresses `<target>` |
| `provider-api-key`                 | supplied  | every gateway's LLM provider                            |

Both directions of every declared edge exist, whether or not both are used:
openclaw's peer schema requires `token` even on a peer that is only ever
called.

`make deploy` is idempotent. On upgrade the chart reads the live Secret back
with Helm's `lookup` and preserves what it finds, so there is no bootstrap
sequence and no pair of alternating secret names — running it twice changes
nothing and rolls nothing.

`make secrets-rotate` bumps a `generation` counter, which is itself stored in
the Secret. Generated values are re-derived only when the requested generation
differs from the recorded one; a `checksum/secrets` annotation on every
StatefulSet then rolls the pods. That checksum covers the *whole* resolved map,
so rotating any one credential rolls the entire fleet — consistent with how
rotation already behaved, and cheaper to reason about than a per-gateway slice.
The counter is read back out of the cluster rather than tracked in a file, so
there is no local state to drift.

The supplied provider key is preserved across a rotation, and preserved when
passed in empty — nothing in the chart could recreate it. `make deploy` pipes
it in on stdin rather than via `--set`, so it stays out of `ps` output and
shell history.

The Secret carries `helm.sh/resource-policy: keep`. `helm uninstall` leaves it
behind, and a later reinstall picks the same credentials back up.

### Where the IRC password actually goes

The shared secret is the IRC `PASS`, which suits rotation because both ends
read it at connection time and neither stores derived state from it.

ergo only ever accepts bcrypt hashes. Rather than hashing at rotation time and
storing a second artifact, the ergo pod's init container runs `ergo genpasswd`
against the plaintext at startup and writes `ERGO__SERVER__PASSWORD` into a
tmpfs that only that pod can read. No hash is stored, shipped, or rotated
separately from the plaintext it came from.

openclaw reads the plaintext from a file (`channels.irc.passwordFile`) rather
than from its environment, where its own agent could read it back. It refuses a
`passwordFile` that is a symlink, and every key in a Kubernetes Secret mount is
one, so its init container copies the value onto a tmpfs as a regular file.

### Where the A2A tokens actually go

Two places, for two different readers.

**Into `openclaw.json`, as literals.** openclaw compares
`channels.a2a.peers.*.token` as a plain string; it is not a SecretRef and it
resolves no `${ENV}` template, whatever the channel doc implies. So the chart
has to put the real value in the file — but it puts a `__ASI_SECRET_*__`
placeholder in the *ConfigMap* and has `render.sh` substitute it from the
Secret mount at boot, so `kubectl get configmap` stays free of credentials. The
value passes through sed's argv, which is safe in this one place: Kubernetes
does not share a PID namespace between containers by default, and the init
container has exited before the gateway — and therefore the agent's shell —
ever starts.

**Onto tmpfs, for the agent.** A gateway that calls a peer also gets
`/var/run/asi/creds/a2a-<peer>-outbound`. That one is read by the *agent*, not
by openclaw: the calling convention is a curl, so the token goes from disk
straight into a header and never passes through the model's context. Same
handling as the IRC PASS, for the same reason.

This is worth re-checking on an openclaw upgrade. It came from reading the
plugin's TypeScript inside the image, and the published docs disagree with the
source on exactly this point — see the design doc's *Re-deriving the findings*.

## What has to be true before the bot answers

Reaching a reply in `#asi` clears six independent gates. Each one fails
quietly — the gateway logs `ready`, the bot sits in the channel, and nothing
looks broken — so they are worth knowing as a set. In order:

| Gate | Config | Symptom when unset |
| ---- | ------ | ------------------ |
| plugin is trusted | staged into `~/.openclaw/npm` by the init container | `openChannelIngressQueue is only available for trusted plugins`, channel retries forever |
| channel is allowlisted | `irc.groups` has an entry for it | `drop channel #asi (not allowlisted)` |
| sender is allowlisted | that entry's `allowFrom` | `drop group sender <mask> (policy=allowlist)` |
| message addresses the bot | that entry's `requireMention` | `drop channel #asi (missing-mention)` |
| a binding matches | that agent's `bindings` in `agent.yaml` | silence — `ownership: explicit` is set fleet-wide, so there is no sole-agent fallback and an uncovered surface fails closed |
| model and harness load | `openclaw.plugins.allow` names them | bot replies `No reply was generated for this message`; log shows `Agent harness runtime "codex" is unavailable` |

The binding gate is new with the fleet and is the one that changed behaviour
for `main`: it used to be routed by openclaw's sole-agent fallback and is now
routed by an explicit binding. The chart refuses to render when an agent has
*no* bindings at all, but it cannot tell whether the ones it has cover every
channel the gateway joins — bind `#notes` while joining `#asi` and it renders
fine and answers nothing.

The last one is the least obvious and the easiest to hit again. `plugins.allow`
is an *exclusive* allowlist over every plugin, not just channels — the model
provider (`openai`) and the agent harness (`codex`) are plugins too. Omitting
them costs nothing at startup and everything at reply time. Changing
`provider` means changing that list to match.

Two traps in the same area, both of which look like the answer and are not:

- **`groupAllowFrom` is not the channel allowlist.** It reads exactly like it
  should be, and the plugin consults it only to narrow `groupPolicy: open`.
  Under `allowlist` it gates nothing. The real allowlist is `groups`, where a
  channel is admitted by *having an entry* — `{}` is a complete one.
- **`allowFrom` does not cover channels.** The plugin sets
  `groupAllowFromFallbackToAllowFrom: false`, so the top-level `allowFrom`
  applies to DMs only. Channel senders come from the per-group `allowFrom`.

## Why the nick is not registered

The obvious fix for the wrong-nick problem is to register `openclaw` with
ergo's NickServ, since the plugin has a `channels.irc.nickserv` block and its
collision handler already sends `GHOST <nick> <password>`. **This was built,
measured, and reverted — it makes things strictly worse.** Two reasons, both
verified against ergo 2.19.1:

1. **The GHOST never works.** `GHOST <nick> <password>` is Atheme/Anope
   syntax. ergo's is `GHOST <nickname>`, with no password argument, and it
   "disconnects the given user *if they're logged in with the same user
   account*" — so it needs an already-authenticated session. The plugin sends
   it before registration completes, unauthenticated, with an extra argument.
   ergo has no `REGAIN` either.
2. **Registering costs the bot its nick permanently.** The plugin speaks no
   SASL and no CAP — it is a bare RFC1459 client that sends `NICK` while
   unauthenticated and only identifies to NickServ after `001`. ergo's
   `nick-reservation: strict` refuses a reserved nick to a client that is not
   logged in. So once `openclaw` is a registered account, every connect gets
   `433` and falls back — measured on a clean restart with nothing whatsoever
   holding the nick, the bot came up as `openclaw_2`.

`register: true` compounds it: each fallback registers a *new* junk account
named after the fallback nick (`openclaw_`, `openclaw_2`, …), and ergo warns
that an unregistered account name stays reserved and cannot be re-registered.
Recovering from the experiment meant deleting `ircd.db`.

Making this work needs a change outside the chart — SASL in the plugin, or
ergo's GHOST syntax in the plugin's collision handler. Until then `make
restart` is the fix, and the nick stays unregistered.

## Notes

- **ergo config**: the chart does not maintain an `ircd.yaml`. The init
  container rebuilds it from the image's bundled `default.yaml` on every boot,
  so it tracks the image, and the handful of settings this chart cares about
  are layered on as `ERGO__*` environment overrides. `ircd.db` and the
  self-signed keypair persist on the PVC beside it.
- **`login-via-pass-command` is off.** Upstream reads `PASS` as
  `account:password` for clients too old for SASL, which ergo refuses to
  combine with a server password. Here `PASS` *is* the shared secret.
- **The plaintext listener is on all interfaces**, unlike upstream's
  loopback-only default, because openclaw dials in from its own pod. Traffic
  stays on the pod network; 6697 is the one to expose off-cluster.
- **`helm template` cannot see `lookup`.** Rendered offline, every generated
  credential comes out as a throwaway random value. Good for reading the
  manifests, useless for diffing them.
- **A plugin installed by hand into a running pod does not survive a restart.**
  The init container rewrites both halves of what an install touches — the
  chart's `openclaw.json` over whatever openclaw wrote in place, and the
  image's staged tree over `~/.openclaw/npm`. Bake it into the image instead.
- **`pullPolicy` is `IfNotPresent` for openclaw** because the image is
  side-loaded rather than pulled. `Always` would fail on a cluster that already
  has the image and no way to fetch it.
- **Every gateway runs the same image.** A variant differs by prompt or model,
  never by build, so `make image` is still one build for the whole fleet.
- **A2A does no NAT traversal.** It is HTTP JSON-RPC to a URL the caller must
  already be able to reach, and `advertisedUrl` exists only so a proxy can
  front it. If a gateway ever leaves the cluster the peer URL changes and
  nothing else does; openclaw's answers to an unroutable peer (Tailscale Serve,
  Reef's relay) sit below A2A and are a different channel and trust model.
- **The A2A task store is per-process and per-peer.** In-memory, pruned at 24h
  or 500 entries, cleared on `stop()`, and scoped to the peer that created the
  task. A pod roll loses the running job *and* the handle, and the next
  `GetTask` returns `-32001 Task not found` — indistinguishable from expired.
  Don't build anything on it surviving a restart.
- **`make irc` needs a TLS-aware client invocation.** ergo's 6697 listener is
  TLS-only and its certificate is self-signed, so a client has to be told to
  use TLS and told not to verify. No client infers either from the port
  number. In irssi that is `/connect -tls localhost 6697 <password>`, with
  `-tls_verify` deliberately absent. Connecting in plaintext is dropped
  mid-handshake and shows up as an instant disconnect with no error on either
  side — ergo logs only `Client connecting` followed by `Disconnecting session
  of *`. `make irc` prints the exact line to paste.
- **An ungraceful restart can leave openclaw connected under the wrong nick.**
  ergo waits `idle-timeouts.disconnect` (2m30s) before reaping a session whose
  socket died without closing; openclaw reconnects in about a second. Anything
  landing inside that window — SIGKILL, OOM, node loss, or a host suspend that
  freezes both ends with the socket still open — finds `openclaw` held by its
  own corpse, falls back to `openclaw_`, and stays there. It does not rejoin
  either, which reads as "the bot is offline": `WHOIS openclaw` gives `401 No
  such nick` while `#asi` sits empty, and openclaw logs nothing at all. No
  retry fires, because from the plugin's side the connection *succeeded* — the
  reconnect monitor only watches for the socket closing. `make
  restart-gateway` is the fix (it defaults to `main`, the only gateway on
  IRC), and is deliberately narrower than `make restart`: rolling ergo would
  disconnect everyone on the network to repair one client. A clean restart never trips this in the first place — SIGTERM
  closes the socket and ergo reaps the session at once, which is why `make
  deploy` is unaffected.
- **A crash-looping pod blocks its own replacement.** A StatefulSet rolling
  update will not proceed past a pod that never becomes Ready, so a change that
  fixes a crash loop needs the pod deleted by hand — or rolled with
  `make restart-ergo` / `make restart-gateway GATEWAY=<name>`, whichever is
  stuck.

## Beyond a dev cluster

Generated credentials exist only in the cluster: lose it and they are gone, and
there is no audit trail of when anything rotated. If this ever outgrows k3d,
the upgrade is SOPS + age — encrypted values in git, history as the rotation
log, and `helm template` that renders what actually gets applied. That needs
`sops` and `age` added to `default.nix` and a decrypt step in `deploy`.
