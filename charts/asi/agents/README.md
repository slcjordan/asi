# Agent definitions

One directory per agent. The directory name is the openclaw agent id, and a
directory is an agent only if it contains `agent.yaml`.

```
agents/
  main/
    agent.yaml     # config: agents.entries.main, plus routing bindings
    AGENTS.md      # the definition -- injected into the system prompt
    BOOTSTRAP.md
    IDENTITY.md
    SOUL.md
    USER.md
```

The chart renders these into `openclaw.json` (`agents.defaults`,
`agents.entries`, and the top-level `bindings`) and copies the `*.md` files into
each agent's workspace at boot. Nothing here needs a matching entry in
`values.yaml`; adding a directory is enough.

## The `.md` files are behaviour, not documentation

openclaw injects the workspace's `AGENTS.md`, `SOUL.md`, `IDENTITY.md`,
`USER.md` and `BOOTSTRAP.md` into the system prompt on every turn. Editing
`SOUL.md` changes how the agent acts.

They have to be *in the workspace* to be injected — openclaw has no config key
for a system prompt and none for context files elsewhere — so an init container
copies them in from a ConfigMap. Two consequences:

- **The chart owns these filenames and rewrites them on every boot.** A
  persona edit in git reaches the agent on the next roll, and the pod rolls
  automatically because the ConfigMap's checksum is on the pod template.
  Equally, anything the agent wrote over one of these files is gone after a
  restart. Everything *else* in the workspace is the agent's own and is never
  touched.
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

Don't set `entry.workspace` unless you mean it: the chart fills it in and the
init container seeds that same path, so overriding it moves both together and
is easy to get half-right.

## Adding a second agent

Adding one changes the rules, because openclaw's sole-agent fallback stops
applying:

1. **Every agent needs `bindings`.** An explicit fleet with no matching binding
   *fails closed* — the bot goes quiet rather than guessing an owner. The chart
   refuses to render if any agent lacks one, so this surfaces at `make deploy`
   rather than as silence in `#asi`.
2. **Workspaces move.** A sole agent owns `~/.openclaw/workspace` directly; in
   a fleet each agent gets `~/.openclaw/workspace/<id>`. The existing agent's
   workspace path therefore changes when you add a second, and its previous
   working files stay behind at the old root.
3. **Ambient services need an owner.** openclaw warns that a multi-agent config
   with no `agents.defaults.heartbeat.agentId` or
   `agents.defaults.systemAgent.agentId` leaves heartbeats disabled. Set one
   through `openclaw.agents.defaults` in `values.yaml`.
4. **Channels still have to be joined.** `bindings` decide which agent handles a
   channel; `openclaw.irc.channels` and `irc.groups` still decide which channels
   the bot joins and listens to at all. A binding for a channel that is not
   joined does nothing.
