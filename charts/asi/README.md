# asi

An IRC network you own, with an assistant sitting on it: [ergo](https://github.com/ergochat/ergo)
as the ircd and [openclaw](https://docs.openclaw.ai) attached to it as a bot.

Everything is driven from the repository root `Makefile`, which reads
`KUBE_CONTEXT` and `KUBE_NAMESPACE` from the selected `envs/*.mk`:

```
make env-dev        # select an environment
make image          # build the openclaw image and load it into the cluster
make deploy         # install or upgrade
make secrets-rotate # re-derive credentials and roll both workloads
make help           # everything else
```

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

## Credentials

Four values live in one Secret, `<release>-secrets`. Three are **generated** by
the chart; one is **supplied** by you. The distinction is the whole design:

| Key                      | Origin    | Used by                                              |
| ------------------------ | --------- | ---------------------------------------------------- |
| `irc-server-password`    | generated | shared -- ergo's `PASS` gate, openclaw's `passwordFile` |
| `irc-oper-password`      | generated | ergo, for `/OPER admin <password>`                   |
| `openclaw-gateway-token` | generated | openclaw's control UI and API                        |
| `provider-api-key`       | supplied  | openclaw's LLM provider                              |

`make deploy` is idempotent. On upgrade the chart reads the live Secret back
with Helm's `lookup` and preserves what it finds, so there is no bootstrap
sequence and no pair of alternating secret names — running it twice changes
nothing and rolls nothing.

`make secrets-rotate` bumps a `generation` counter, which is itself stored in
the Secret. Generated values are re-derived only when the requested generation
differs from the recorded one; a `checksum/secrets` annotation on both
StatefulSets then rolls the pods that need the new values. The counter is read
back out of the cluster rather than tracked in a file, so there is no local
state to drift.

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

## What has to be true before the bot answers

Reaching a reply in `#asi` clears five independent gates. Each one fails
quietly — the gateway logs `ready`, the bot sits in the channel, and nothing
looks broken — so they are worth knowing as a set. In order:

| Gate | Config | Symptom when unset |
| ---- | ------ | ------------------ |
| plugin is trusted | staged into `~/.openclaw/npm` by the init container | `openChannelIngressQueue is only available for trusted plugins`, channel retries forever |
| channel is allowlisted | `irc.groups` has an entry for it | `drop channel #asi (not allowlisted)` |
| sender is allowlisted | that entry's `allowFrom` | `drop group sender <mask> (policy=allowlist)` |
| message addresses the bot | that entry's `requireMention` | `drop channel #asi (missing-mention)` |
| model and harness load | `openclaw.plugins.allow` names them | bot replies `No reply was generated for this message`; log shows `Agent harness runtime "codex" is unavailable` |

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
  restart-openclaw` is the fix, and is deliberately narrower than `make
  restart`: rolling ergo would disconnect everyone on the network to repair
  one client. A clean restart never trips this in the first place — SIGTERM
  closes the socket and ergo reaps the session at once, which is why `make
  deploy` is unaffected.
- **A crash-looping pod blocks its own replacement.** A StatefulSet rolling
  update will not proceed past a pod that never becomes Ready, so a change that
  fixes a crash loop needs the pod deleted by hand — or rolled with
  `make restart-ergo` / `make restart-openclaw`, whichever is stuck.

## Beyond a dev cluster

Generated credentials exist only in the cluster: lose it and they are gone, and
there is no audit trail of when anything rotated. If this ever outgrows k3d,
the upgrade is SOPS + age — encrypted values in git, history as the rotation
log, and `helm template` that renders what actually gets applied. That needs
`sops` and `age` added to `default.nix` and a decrypt step in `deploy`.
