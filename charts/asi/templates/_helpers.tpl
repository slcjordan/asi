{{- define "asi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "asi.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "asi.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "asi.ergo.fullname" -}}
{{- printf "%s-ergo" (include "asi.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "asi.collector.fullname" -}}
{{- printf "%s-otel-collector" (include "asi.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
One gateway's workload name. Takes {root, key}.

This is the name that replaced `<fullname>-openclaw` when the chart became a
fleet, so the sole gateway of the old layout is now `<fullname>-main` and its
volume is `data-<fullname>-main-0`. There is no compatibility shim: see
docs/design/gateway-fleet.md#blast-radius for why the rename was taken rather
than pinned.
*/}}
{{- define "asi.gateway.fullname" -}}
{{- printf "%s-%s" (include "asi.fullname" .root) .key | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Where one gateway is reachable from inside the cluster. Takes {root, key}.
This is both `channels.a2a.advertisedUrl` on the callee and the host half of
`peers.<name>.url` on the caller, so the two agree by construction.
*/}}
{{- define "asi.gateway.url" -}}
{{- printf "http://%s:%d" (include "asi.gateway.fullname" .) (int .root.Values.openclaw.gateway.port) -}}
{{- end -}}

{{/*
Secret key for one direction of one A2A edge. Takes {target, caller}: the
bearer `caller` presents when it addresses `target`, which is therefore also
the value `target` compares against on the way in.

Named for what the caller *addresses* rather than for a pair, because both
directions of an edge exist (openclaw's peer schema requires `token` even on a
peer that is only ever called) and `<target>-from-<caller>` is the only naming
that stays unambiguous when it does.
*/}}
{{- define "asi.a2a.tokenKey" -}}
{{- printf "a2a-token-%s-from-%s" .target .caller -}}
{{- end -}}

{{/*
Gateway token key for one gateway. One per gateway rather than one shared,
because a gateway is a separate process with a separate control API and
handing them a common bearer would make `make gateway` on one of them a
credential for all of them.
*/}}
{{- define "asi.gateway.tokenKey" -}}
{{- printf "openclaw-gateway-token-%s" . -}}
{{- end -}}

{{/*
Placeholder that stands in for a credential inside the rendered openclaw.json,
substituted by render.sh at boot from the mounted Secret.

This exists because `channels.a2a.peers.*.token` is a plain string compared as
a digest against the presented bearer -- it is not a SecretRef and resolves no
`${ENV}` template (a2a/src/config-schema.ts:12, a2a/src/http.ts:67), so the
chart has to put the real value in the file. Rendering it into the ConfigMap
would make `kubectl get configmap` a credential disclosure, so the ConfigMap
carries this marker and the value arrives from the Secret mount instead --
exactly the treatment the IRC PASS already gets.
*/}}
{{- define "asi.secretPlaceholder" -}}
{{- printf "__ASI_SECRET_%s__" .  -}}
{{- end -}}

{{/*
Resolve the gateway fleet, exactly once per render.

A gateway is one entry under `.Values.gateways` plus one directory of agent
definitions at `agents/<gateway>/<agentId>/`. Everything else -- names, URLs,
A2A peer maps, secret keys, telemetry identity, which credentials have to be
substituted into which config -- derives from those two, so adding the next
gateway is a values entry and a directory and nothing more.

Cached on .Values because Helm renders each template independently and five of
them need the identical answer. This emits nothing; callers read
`.Values.resolvedGateways`, a dict keyed by gateway name.
*/}}
{{- define "asi.gateways" -}}
{{- if not (hasKey .Values "resolvedGateways") -}}
{{- $root := . -}}
{{- $declared := .Values.gateways | default dict -}}
{{- if not $declared -}}
{{- fail "no gateways declared -- `gateways` in values.yaml must hold at least one entry, and every gateway needs a matching agents/<gateway>/ directory" -}}
{{- end -}}
{{/*
Pass one: discover the agent definitions and group them by owning gateway. A
directory is an agent if and only if it holds `agent.yaml` -- an explicit
marker beats guessing from whatever else is in there, and it gives per-agent
config a home next to the prompt content it belongs with.
*/}}
{{- $found := dict -}}
{{- range $path, $_ := .Files.Glob "agents/*/*/agent.yaml" -}}
{{- $parts := splitList "/" $path -}}
{{- $gwKey := index $parts 1 -}}
{{- $agentId := index $parts 2 -}}
{{- if not (hasKey $declared $gwKey) -}}
{{- fail (printf "agents/%s/ has no matching entry under `gateways` in values.yaml -- a directory of agent definitions does not deploy a gateway on its own, and a gateway with nowhere to run is more likely a typo than an intent" $gwKey) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]*$" $agentId) -}}
{{- fail (printf "agent directory %q under agents/%s/ is not a usable openclaw agent id -- use lowercase letters, digits and hyphens" $agentId $gwKey) -}}
{{- end -}}
{{- $raw := ($root.Files.Get $path | fromYaml) | default dict -}}
{{/* fromYaml reports a parse failure as an "Error" key rather than failing. */}}
{{- if hasKey $raw "Error" -}}
{{- fail (printf "agents/%s/%s/agent.yaml is not valid YAML: %v" $gwKey $agentId (get $raw "Error")) -}}
{{- end -}}
{{- $_ := set $found $gwKey (merge (dict $agentId $raw) (get $found $gwKey | default dict)) -}}
{{- end -}}
{{/*
Pass two: the edge list. Every `a2a.calls` entry is one directed edge, and
both directions of it are minted -- see asi.a2a.tokenKey.
*/}}
{{- $callersOf := dict -}}
{{- range $key, $spec := $declared -}}
{{- range $target := ((($spec | default dict).a2a | default dict).calls | default list) -}}
{{- if not (hasKey $declared $target) -}}
{{- fail (printf "gateway %q calls %q over A2A, but %q is not declared under `gateways`" $key $target $target) -}}
{{- end -}}
{{- if eq $target $key -}}
{{- fail (printf "gateway %q lists itself in a2a.calls -- a gateway reaches its own agents directly, not over A2A" $key) -}}
{{- end -}}
{{- $_ := set $callersOf $target (append (get $callersOf $target | default list) $key) -}}
{{- end -}}
{{- end -}}
{{/*
Pass three: resolve each gateway.
*/}}
{{- $resolved := dict -}}
{{- $workspaceRoot := .Values.openclaw.agents.workspaceRoot -}}
{{- range $key, $spec := $declared -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]*$" $key) -}}
{{- fail (printf "gateway %q is not a usable name -- it becomes a Kubernetes object name, so use lowercase letters, digits and hyphens" $key) -}}
{{- end -}}
{{- $spec = $spec | default dict -}}
{{- $agentDefs := get $found $key | default dict -}}
{{- if not $agentDefs -}}
{{- fail (printf "gateway %q has no agents -- create agents/%s/<agentId>/agent.yaml, because a gateway with no agent starts, answers nothing, and looks healthy doing it" $key $key) -}}
{{- end -}}
{{- $agentIds := keys $agentDefs | sortAlpha -}}
{{/*
Agents. No `$multi` branch: the workspace is always `<root>/<agentId>` and a
binding is always required, so no agent's path or routing depends on how many
others happen to exist. Adding an agent -- or a gateway -- can no longer move
another one's workspace out from under it. See
docs/design/gateway-fleet.md#chart-shape.
*/}}
{{- $entries := dict -}}
{{- $bindings := list -}}
{{- $files := dict -}}
{{- $workspaces := dict -}}
{{- range $agentId := $agentIds -}}
{{- $def := get $agentDefs $agentId -}}
{{- $entry := (get $def "entry") | default dict -}}
{{- $workspace := printf "%s/%s" $workspaceRoot $agentId -}}
{{- if hasKey $entry "workspace" -}}
{{- $workspace = get $entry "workspace" -}}
{{- else -}}
{{- $_ := set $entry "workspace" $workspace -}}
{{- end -}}
{{- $_ := set $workspaces $agentId $workspace -}}
{{- $_ := set $entries $agentId $entry -}}
{{/*
Routing fails closed: a surface with no matching binding goes quiet rather
than picking an owner, and `agents.ownership: "explicit"` is set on every
gateway now, so there is no sole-agent fallback anywhere to lean on. Refuse to
render instead of shipping a bot that has stopped answering.

The check only tests that the list is non-empty. It cannot tell whether the
bindings actually cover every channel the gateway joins -- that gap is real
and unchanged.
*/}}
{{- $agentBindings := (get $def "bindings") | default list -}}
{{- if not $agentBindings -}}
{{- fail (printf "agent %q on gateway %q defines no bindings -- routing is explicit fleet-wide, so a surface with no matching binding fails closed and the agent never answers; give it a bindings entry in agents/%s/%s/agent.yaml" $agentId $key $key $agentId) -}}
{{- end -}}
{{- range $binding := $agentBindings -}}
{{- $bindings = append $bindings (merge (dict "agentId" $agentId) $binding) -}}
{{- end -}}
{{- $agentFiles := list -}}
{{- range $path, $_ := $root.Files.Glob (printf "agents/%s/%s/*.md" $key $agentId) -}}
{{- $agentFiles = append $agentFiles $path -}}
{{- end -}}
{{- $_ := set $files $agentId ($agentFiles | sortAlpha) -}}
{{- end -}}
{{/*
IRC, per gateway. The shared block under `openclaw.irc` supplies everything;
a gateway entry only decides whether this one joins at all, plus whatever it
wants to differ on.

Worth remembering before turning this on for a second gateway: IRC has no
`allowBots`, so openclaw's bot-loop protection cannot recognise another
openclaw as a bot. Two of them in one channel under the current
`allowFrom: ["*"]` / `requireMention: false` answer each other forever.
*/}}
{{- $irc := mergeOverwrite (deepCopy $root.Values.openclaw.irc) (get $spec "irc" | default dict) -}}
{{- $messages := mergeOverwrite (deepCopy $root.Values.openclaw.messages) (get $spec "messages" | default dict) -}}
{{/*
A2A. `calls` is what this gateway may address; the reverse list is derived, so
declaring an edge once wires both ends. The channel defaults to on exactly
when the gateway is on one end of an edge, and can be forced on to stand the
plugin up before any peer exists.
*/}}
{{- $a2aSpec := get $spec "a2a" | default dict -}}
{{- $calls := get $a2aSpec "calls" | default list | sortAlpha -}}
{{- $callers := get $callersOf $key | default list | uniq | sortAlpha -}}
{{- $a2aEnabled := or (gt (len $calls) 0) (gt (len $callers) 0) -}}
{{- if hasKey $a2aSpec "enabled" -}}
{{- $a2aEnabled = get $a2aSpec "enabled" -}}
{{- end -}}
{{/*
The peer map, and the credentials it needs substituted into it. A peer this
gateway calls gets a URL and an outbound bearer; every peer, called or not,
also gets the inbound `token` its schema requires.
*/}}
{{- $peers := dict -}}
{{- $secretRefs := list -}}
{{- $outbound := dict -}}
{{- range $peer := (concat $calls $callers | uniq | sortAlpha) -}}
{{- $inKey := include "asi.a2a.tokenKey" (dict "target" $key "caller" $peer) -}}
{{- $entry := dict "token" (include "asi.secretPlaceholder" $inKey) -}}
{{- $secretRefs = append $secretRefs $inKey -}}
{{- if has $peer $calls -}}
{{- $outKey := include "asi.a2a.tokenKey" (dict "target" $peer "caller" $key) -}}
{{- $_ := set $entry "url" (printf "%s/a2a/v1" (include "asi.gateway.url" (dict "root" $root "key" $peer))) -}}
{{- $_ := set $entry "outboundToken" (include "asi.secretPlaceholder" $outKey) -}}
{{- $secretRefs = append $secretRefs $outKey -}}
{{- $_ := set $outbound $peer $outKey -}}
{{- end -}}
{{- $_ := set $peers $peer $entry -}}
{{- end -}}
{{/*
Telemetry identity. Both of these were single-gateway assumptions: left
shared, every span from every pod would claim `openclaw-gateway` and `main`,
and the two fleets would be indistinguishable in the collector.
*/}}
{{- $otel := $root.Values.openclaw.otel -}}
{{- $serviceName := printf "%s-%s" $otel.serviceName $key -}}
{{- $otelAgent := $otel.resource.agent | default "" -}}
{{- if and (not $otelAgent) (eq (len $agentIds) 1) -}}
{{- $otelAgent = first $agentIds -}}
{{- end -}}
{{/*
And so was the workspace fingerprint path, which never had a `$multi` guard at
all: hardcoded to the sole-agent root, it would have covered the *parent* of
every workspace the moment a second agent existed -- silently. Derived per
agent it is right by construction, for the one-agent case that is every
gateway here. A gateway that grows a second agent falls back to the root and
inherits that same imprecision, which is why the comment below says so out
loud rather than pretending the case is handled.
*/}}
{{- $workspacePath := $workspaceRoot -}}
{{- if eq (len $agentIds) 1 -}}
{{- $workspacePath = get $workspaces (first $agentIds) -}}
{{- end -}}
{{- $_ := set $resolved $key (dict
      "key" $key
      "fullname" (include "asi.gateway.fullname" (dict "root" $root "key" $key))
      "url" (include "asi.gateway.url" (dict "root" $root "key" $key))
      "irc" $irc
      "messages" $messages
      "post" (get $spec "post" | default dict)
      "a2a" (dict
        "enabled" $a2aEnabled
        "calls" $calls
        "callers" $callers
        "peers" $peers
        "outbound" $outbound)
      "secretRefs" ($secretRefs | uniq | sortAlpha)
      "tokenKey" (include "asi.gateway.tokenKey" $key)
      "agentIds" $agentIds
      "entries" $entries
      "bindings" $bindings
      "files" $files
      "workspaces" $workspaces
      "weight" (get $spec "weight" | default 1)
      "resources" (get $spec "resources" | default $root.Values.openclaw.resources)
      "persistence" (mergeOverwrite (deepCopy $root.Values.openclaw.persistence) (get $spec "persistence" | default dict))
      "extraEnv" (mergeOverwrite (deepCopy $root.Values.openclaw.extraEnv) (get $spec "extraEnv" | default dict))
      "otelServiceName" $serviceName
      "otelAgent" $otelAgent
      "workspacePath" $workspacePath) -}}
{{- end -}}
{{/*
Nick collisions, now that more than one gateway is on the network.

ergo hands the nick to whoever registers first and the loser falls back to
`<nick>_`. That is the same state `make restart-gateway` exists to repair,
except permanent and racing on every roll -- and it is invisible from the
config, because both gateways look correctly configured. Two gateways asking
for one nick is never deliberate, so refuse rather than deploy a coin flip.
*/}}
{{- $nicks := dict -}}
{{- range $key, $gw := $resolved -}}
{{- if $gw.irc.enabled -}}
{{- $nick := $gw.irc.nick -}}
{{- if hasKey $nicks $nick -}}
{{- fail (printf "gateways %q and %q both join IRC as %q -- ergo gives the nick to whichever registers first and renames the other to %q_, so set gateways.<name>.irc.nick on one of them" (get $nicks $nick) $key $nick $nick) -}}
{{- end -}}
{{- $_ := set $nicks $nick $key -}}
{{- end -}}
{{- end -}}
{{- $_ := set .Values "resolvedGateways" $resolved -}}
{{- end -}}
{{- end -}}

{{/*
Every secret key the fleet needs, with the length to generate it at. Derived
rather than listed, so an edge added in values.yaml mints its credentials
without a second edit here.
*/}}
{{- define "asi.secretLengths" -}}
{{- include "asi.gateways" . -}}
{{- $lengths := dict
      "irc-server-password" .Values.secrets.lengths.ircServerPassword
      "irc-oper-password" .Values.secrets.lengths.ircOperPassword -}}
{{- range $key, $gw := .Values.resolvedGateways -}}
{{- $_ := set $lengths $gw.tokenKey $.Values.secrets.lengths.openclawGatewayToken -}}
{{- range $ref := $gw.secretRefs -}}
{{- $_ := set $lengths $ref $.Values.secrets.lengths.a2aToken -}}
{{- end -}}
{{- end -}}
{{- $lengths | toYaml -}}
{{- end -}}

{{/*
Where openclaw sends OTLP. An explicit endpoint wins; otherwise it is the
collector this chart deploys. Turning the collector off without naming a
replacement is a configuration error rather than a default, because the
alternative is a pod that looks healthy while every export attempt is refused.
*/}}
{{- define "asi.otel.endpoint" -}}
{{- with .Values.openclaw.otel.endpoint -}}
{{- . -}}
{{- else -}}
{{- if not .Values.otelCollector.enabled -}}
{{- fail "openclaw.otel.enabled is true but otelCollector.enabled is false and openclaw.otel.endpoint is empty -- set an endpoint to export somewhere, or disable openclaw.otel" -}}
{{- end -}}
{{- printf "http://%s:%d" (include "asi.collector.fullname" .) (int .Values.otelCollector.otlpHttpPort) -}}
{{- end -}}
{{- end -}}

{{/*
OTEL_RESOURCE_ATTRIBUTES for one gateway. Takes {root, gw}.

This is how `agent` and `agent version` reach the spans at all: neither is
exported as a span attribute on tool or exec spans, but the exporter runs the
standard env resource detector and merges what it finds onto every span the
process emits. Only `service.name` is set from openclaw's own config, so it is
the one key not to write here -- it would lose the merge anyway.
*/}}
{{- define "asi.otel.resourceAttributes" -}}
{{- $resource := .root.Values.openclaw.otel.resource -}}
{{- $attrs := dict
      "openclaw.agent" .gw.otelAgent
      "service.version" ($resource.version | default .root.Values.openclaw.image.tag) -}}
{{- range $key, $value := $resource.extra -}}
{{- $_ := set $attrs $key $value -}}
{{- end -}}
{{- $pairs := list -}}
{{- range $key, $value := $attrs -}}
{{- if $value -}}
{{- $pairs = append $pairs (printf "%s=%s" $key (toString $value)) -}}
{{- end -}}
{{- end -}}
{{- join "," $pairs -}}
{{- end -}}

{{/*
Not overridable on purpose -- the Makefile computes this same name on its own
and would go looking at the wrong Secret if the chart could be pointed
elsewhere. See values.yaml.
*/}}
{{- define "asi.secretName" -}}
{{- printf "%s-secrets" (include "asi.fullname" .) -}}
{{- end -}}

{{- define "asi.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "asi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Resolve every credential, exactly once per render.

Generated credentials are read back out of the live Secret with `lookup`, so a
plain `helm upgrade` preserves them and no bootstrap dance is needed. They are
re-derived only when `secrets.generation` differs from the generation recorded
in the Secret. The provider API key is *supplied*, not generated, so it is
preserved across a rotation and preserved when passed in empty -- nothing here
can recreate it.

Which keys exist is derived from the fleet (see asi.secretLengths), so the set
grows with the gateway map rather than being listed twice.

The resolved map is cached on .Values because Helm renders each template
independently: without the cache, every `randAlphaNum` call would hand a
different string to a different file, and the Secret would disagree with the
checksum annotations that are supposed to track it. This emits nothing;
callers read `.Values.resolvedSecrets` afterwards.
*/}}
{{- define "asi.secrets" -}}
{{- if not (hasKey .Values "resolvedSecrets") -}}
{{- $live := (lookup "v1" "Secret" .Release.Namespace (include "asi.secretName" .)) | default dict -}}
{{- $data := (get $live "data") | default dict -}}
{{- $generation := .Values.secrets.generation | toString -}}
{{- $recorded := "" -}}
{{- if hasKey $data "generation" -}}
{{- $recorded = index $data "generation" | b64dec -}}
{{- end -}}
{{- $keep := eq $generation $recorded -}}
{{- $lengths := include "asi.secretLengths" . | fromYaml -}}
{{- $resolved := dict "generation" $generation -}}
{{- range $key, $length := $lengths -}}
{{- $value := "" -}}
{{- if and $keep (hasKey $data $key) -}}
{{- $value = index $data $key | b64dec -}}
{{- end -}}
{{- if not $value -}}
{{- $value = randAlphaNum (int $length) -}}
{{- end -}}
{{- $_ := set $resolved $key $value -}}
{{- end -}}
{{- $apiKey := .Values.openclaw.provider.apiKey | default "" -}}
{{- if and (not $apiKey) (hasKey $data "provider-api-key") -}}
{{- $apiKey = index $data "provider-api-key" | b64dec -}}
{{- end -}}
{{- $_ := set $resolved "provider-api-key" $apiKey -}}
{{- $_ := set .Values "resolvedSecrets" $resolved -}}
{{- end -}}
{{- end -}}

{{/*
ConfigMap key for one definition file. Keys may not contain "/", so the agent
id is folded in with a separator and the volume's `items` maps it back to a
nested path at mount time. The gateway is not in the key: there is one agents
ConfigMap per gateway now, so it is in the object's *name* instead.
*/}}
{{- define "asi.agents.key" -}}
{{- printf "%s--%s" (index (splitList "/" .path) 2) (base .path) -}}
{{- end -}}

{{/*
Fingerprint of the resolved credentials, for the pod annotations that decide
when a rotation has to roll a workload. Fleet-wide by design: rotating any one
credential rolls every pod, which is what rotation already did and is cheaper
to reason about than a per-gateway slice of the map.
*/}}
{{- define "asi.secrets.checksum" -}}
{{- include "asi.secrets" . -}}
{{- .Values.resolvedSecrets | toYaml | sha256sum -}}
{{- end -}}

{{/*
Where each workload mounts the credential Secret, and the files it reads from
there. ergo bcrypts what it needs at startup; openclaw reads the plaintext.
*/}}
{{- define "asi.secretMountPath" -}}/var/run/asi/secrets{{- end -}}

{{/*
tmpfs scratch for credentials that have to exist as regular files rather than
as the symlinks a Secret mount provides -- and, for the A2A outbound bearers,
so the calling agent can `cat` one into a curl header without the token ever
passing through the model's context.
*/}}
{{- define "asi.credsMountPath" -}}/var/run/asi/creds{{- end -}}

{{/*
Scripts the *agent* runs, as opposed to the ones the init containers run. Only
`pick-poet-gateway` lives here today; see the A/B selection rule in
docs/design/gateway-fleet.md.
*/}}
{{- define "asi.binMountPath" -}}/var/run/asi/bin{{- end -}}

{{/*
tmpfs handoff for the workspace fingerprint. The init container computes it and
the gateway's wrapper reads it back: a pod's env is fixed when the pod is
created, so a value that only exists once the volume is mounted cannot be
passed any other way.
*/}}
{{- define "asi.provenanceMountPath" -}}/var/run/asi/provenance{{- end -}}
