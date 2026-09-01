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

# Where the chart's init container copies from, and where under the volume it
# has to land. Nothing reads these labels; they are here so `docker inspect`
# answers the question without a shell.
LABEL ai.openclaw.plugins.stage="/opt/openclaw/npm"
LABEL ai.openclaw.plugins.target=".openclaw/npm"
