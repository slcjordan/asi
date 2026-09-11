# Agent definitions

One directory per gateway, one directory per agent inside it. The outer name is
the gateway that runs the agent — it must have a matching entry under
`gateways` in `values.yaml` — and the inner name is the openclaw agent id. A
directory is an agent only if it contains `agent.yaml`.

```
agents/
  main/                # gateway
    main/              # agent id
      agent.yaml       # config: agents.entries.main, plus routing bindings
      AGENTS.md        # the definition — injected into the system prompt
      BOOTSTRAP.md
      IDENTITY.md
      SOUL.md
      USER.md
  poet-a/
    poet/
      agent.yaml
      AGENTS.md  IDENTITY.md  SOUL.md
  poet-b/
    poet/              # same agent id as poet-a, deliberately — see below
      ...
```

The chart renders these into each gateway's `openclaw.json` (`agents.defaults`,
`agents.entries`, and the top-level `bindings`) and copies the `*.md` files into
each agent's workspace at boot. Adding an agent to an existing gateway is just a
directory; adding a *gateway* needs the values entry too, and the chart refuses
to render if the two disagree in either direction.

**Agent ids only have to be unique within a gateway.** That is what lets
`poet-a` and `poet-b` both run an agent called `poet`: their agent cards and
their bindings match, so the caller's choice of gateway is the only difference
between the two variants, and the A/B compares one thing.

## The `.md` files are behaviour, not documentation

openclaw injects the workspace's `AGENTS.md`, `SOUL.md`, `IDENTITY.md`,
`USER.md` and `BOOTSTRAP.md` into the system prompt on every turn. Editing
`SOUL.md` changes how the agent acts.

They have to be *in the workspace* to be injected — openclaw has no config key
for a system prompt and none for context files elsewhere — so an init container
copies them in from a ConfigMap. Three consequences:

- **The chart owns these filenames and rewrites them on every boot.** A
  persona edit in git reaches the agent on the next roll, and the pod rolls
  automatically because the ConfigMap's checksum is on the pod template.
  Equally, anything the agent wrote over one of these files is gone after a
  restart. Everything *else* in the workspace is the agent's own and is never
  touched.
- **The checksum is per gateway.** There is one agents ConfigMap per gateway,
  so editing `poet-b`'s `SOUL.md` rolls `poet-b` and leaves `main` and
  `poet-a` running — which matters when the point of the edit is to change one
  arm of an A/B while the other stays put.
- **`agents.skipBootstrap` is on**, so openclaw does not generate these files.
  A definition file you do not provide simply does not exist for that agent —
  drop `USER.md` and the agent has no `USER.md`, rather than openclaw supplying
  a default. Set `openclaw.agents.skipBootstrap: false` in `values.yaml` to have
  openclaw fill in whatever the repo leaves out.

openclaw truncates each bootstrap file at 20000 characters and 60000 across all
of them (`bootstrapMaxChars` / `bootstrapTotalMaxChars`), so a very long
persona is silently cut rather than rejected.

## `agent.yaml`

```yaml
# Merged verbatim into openclaw's agents.entries.<dir name>.
entry:
  identity:
    name: Scribe
    emoji: "📝"
  model: openai/gpt-5.4
  skills: []

# Top-level `bindings` entries; agentId is filled in for you.
bindings:
  - match:
      channel: irc
      peer:
        kind: channel
        id: "#notes"
```

`entry` accepts anything openclaw accepts under `agents.entries.*` — `model`,
`utilityModel`, `identity`, `skills`, `tools`, `sandbox`, `runtime`,
`subagents`, `thinkingDefault`, and the rest. Leave it `{}` to inherit every
default.

Don't set `entry.workspace` unless you mean it: the chart fills it in as
`<workspaceRoot>/<agentId>` and the init container seeds that same path, so
overriding it moves both together and is easy to get half-right.

## Bindings are not optional

`agents.ownership: "explicit"` is set on **every** gateway, whatever number of
agents it runs. There is no sole-agent fallback anywhere in the fleet, so:

1. **Every agent needs at least one `bindings` entry.** A surface with no
   matching binding *fails closed* — the agent goes quiet rather than being
   guessed at. The chart refuses to render without one, so this surfaces at
   `make deploy` rather than as silence in `#asi`.
2. **The chart only checks that the list is non-empty.** It cannot tell whether
   your bindings cover every channel the gateway actually joins. A gateway that
   joins `#asi` and binds only `#notes` renders fine and answers nothing.
3. **Channels still have to be joined.** `bindings` decide which agent handles a
   channel; `gateways.<name>.irc.enabled`, `openclaw.irc.channels` and
   `irc.groups` still decide which channels the gateway joins and listens to at
   all. A binding for a channel that is not joined does nothing.
4. **Ambient services need an owner.** openclaw warns that a multi-agent config
   with no `agents.defaults.heartbeat.agentId` or
   `agents.defaults.systemAgent.agentId` leaves heartbeats disabled. Set one
   through `openclaw.agents.defaults` in `values.yaml` if a gateway grows a
   second agent.

## Workspaces never move

Each agent's workspace is `<workspaceRoot>/<agentId>`, always — there is no
sole-agent special case. Adding an agent, or adding a whole gateway, cannot
move an existing agent's workspace out from under it, and the path the chart
writes into `agents.entries.*.workspace` is the same path the init container
seeds by construction rather than by two rules agreeing.
