# openclaw with the IRC channel plugin baked in.
#
# IRC is not built into openclaw. It is an external package, @openclaw/irc,
# that `openclaw plugins install` fetches from npm at *runtime* and unpacks
# under $HOME/.openclaw/npm/projects/. Both halves of that are a problem for a
# StatefulSet: that directory is the PVC, and doing the install at boot instead
# puts an npm fetch on the startup path of every pod with a cold volume.
#
# The install has to land there, though, and not merely somewhere on disk.
# openclaw grades a plugin by where it was loaded from: a directory named in
# `plugins.load.paths` loads with origin "config" and stays untrusted, and an
# untrusted plugin is refused the channel ingress queue -- so the IRC channel
# starts, fails with "openChannelIngressQueue is only available for trusted
# plugins", and retries forever. Only the managed root under $HOME/.openclaw
# yields origin "global", which is what the channel needs.
#
# So the install runs here, at build time, against a throwaway HOME, and the
# whole managed npm tree is staged at /opt/openclaw/npm -- image-owned and
# outside the volume. The chart's init container copies it into place on the
# PVC at boot, which needs no network.

ARG OPENCLAW_VERSION=2026.8.1

FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION} AS build

# Pinned separately from the runtime: the plugin declares
# `peerDependencies.openclaw >= <its own version>`, so it may not lead the
# image it is being baked into.
ARG IRC_PLUGIN_VERSION=2026.8.1

# A HOME the real one never sees. The installer also writes a state sqlite, a
# config journal key, and an openclaw.json recording the install -- all of them
# things the chart or the volume owns at runtime. They stay in this stage.
ENV HOME=/tmp/build-home
WORKDIR /app

# --force accepts a non-ClawHub (npm) source non-interactively;
# --accept-capabilities takes the plugin's declared capabilities as given,
# which is the only answer available in a non-interactive build;
# --pin resolves the tag to an exact version so the layer is reproducible.
RUN mkdir -p "$HOME" \
 && node openclaw.mjs plugins install "npm:@openclaw/irc@${IRC_PLUGIN_VERSION}" \
      --force --accept-capabilities --pin \
 && test -f "$HOME"/.openclaw/npm/projects/*/node_modules/@openclaw/irc/openclaw.plugin.json

FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

# The staged tree is relocatable: the plugin carries its own bundled deps, and
# its `openclaw` peer dependency is an absolute symlink to /app rather than a
# path relative to the HOME it was installed under.
COPY --from=build --chown=node:node /tmp/build-home/.openclaw/npm /opt/openclaw/npm

# Trace context across the gateway boundary, in two halves that are only
# useful together. See docs/design/gateway-fleet.md#tracing-a-dispatch.
#
# Half one: make the A2A route adopt a caller's `traceparent`. openclaw does
# this for the gateway control protocol already and does not do it for A2A, so
# without the patch a dispatch and the run it causes are two unrelated traces.
# The script finds its target by content and exits non-zero if the route has
# moved, which fails the build rather than shipping an image that traces
# nothing. Re-read it whenever OPENCLAW_VERSION moves.
# --chown because the build runs as `node` and /tmp is sticky: a root-owned
# copy here patches fine and then cannot be cleaned up.
COPY --chown=node:node patch-a2a-traceparent.mjs /tmp/patch-a2a-traceparent.mjs
RUN node /tmp/patch-a2a-traceparent.mjs /app/dist \
 && rm /tmp/patch-a2a-traceparent.mjs

# Half two: put the active run's traceparent into the exec tool's environment,
# so the `curl` that dispatches a poem can send the header at all. This is a
# `resolve_exec_env` hook -- a documented extension point -- rather than a
# second patch, so it survives upgrades on its own.
#
# `node_modules/openclaw` is the same absolute-symlink trick the IRC plugin
# relies on: the plugin imports `openclaw/plugin-sdk/...`, and without a peer
# to resolve that against it fails to load with ERR_MODULE_NOT_FOUND. Measured,
# not assumed. It lives here rather than in a ConfigMap for exactly that
# reason -- a ConfigMap cannot carry the symlink.
#
# The chart still has to name it in `openclaw.plugins.allow`, add the path to
# `plugins.load.paths` and enable its entry; being on disk does nothing.
COPY --chown=node:node plugins/asi-trace-env /opt/asi/plugins/asi-trace-env
RUN mkdir -p /opt/asi/plugins/asi-trace-env/node_modules \
 && ln -s /app /opt/asi/plugins/asi-trace-env/node_modules/openclaw

# Where the chart's init container copies from, and where under the volume it
# has to land. Nothing reads these labels; they are here so `docker inspect`
# answers the question without a shell.
LABEL ai.openclaw.plugins.stage="/opt/openclaw/npm"
LABEL ai.openclaw.plugins.target=".openclaw/npm"
