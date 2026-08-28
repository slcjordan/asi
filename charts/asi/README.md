# asi

An IRC network you own, with an assistant sitting on it: [ergo](https://github.com/ergochat/ergo)
as the ircd and [openclaw](https://docs.openclaw.ai) attached to it as a bot.

Everything is driven from the repository root `Makefile`, which reads
`KUBE_CONTEXT` and `KUBE_NAMESPACE` from the selected `envs/*.mk`:

```
make env-dev        # select an environment
make deploy         # install or upgrade
make secrets-rotate # re-derive credentials and roll both workloads
make help           # everything else
```

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
- **A crash-looping pod blocks its own replacement.** A StatefulSet rolling
  update will not proceed past a pod that never becomes Ready, so a change that
  fixes a crash loop needs the pod deleted by hand (or `make restart`).

## Beyond a dev cluster

Generated credentials exist only in the cluster: lose it and they are gone, and
there is no audit trail of when anything rotated. If this ever outgrows k3d,
the upgrade is SOPS + age — encrypted values in git, history as the rotation
log, and `helm template` that renders what actually gets applied. That needs
`sops` and `age` added to `default.nix` and a decrypt step in `deploy`.
