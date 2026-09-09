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

{{- define "asi.openclaw.fullname" -}}
{{- printf "%s-openclaw" (include "asi.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "asi.collector.fullname" -}}
{{- printf "%s-otel-collector" (include "asi.fullname" .) | trunc 63 | trimSuffix "-" -}}
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
OTEL_RESOURCE_ATTRIBUTES, which is how `agent` and `agent version` reach the
spans at all: neither is exported as a span attribute on tool or exec spans,
but the exporter runs the standard env resource detector and merges what it
finds onto every span the process emits. Only `service.name` is set from
openclaw's own config, so it is the one key not to write here -- it would lose
the merge anyway.
*/}}
{{- define "asi.otel.resourceAttributes" -}}
{{- $resource := .Values.openclaw.otel.resource -}}
{{- $attrs := dict
      "openclaw.agent" $resource.agent
      "service.version" ($resource.version | default .Values.openclaw.image.tag) -}}
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
{{- $lengths := dict
      "irc-server-password" .Values.secrets.lengths.ircServerPassword
      "irc-oper-password" .Values.secrets.lengths.ircOperPassword
      "openclaw-gateway-token" .Values.secrets.lengths.openclawGatewayToken -}}
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
Discover the agent definitions in charts/asi/agents/ and resolve them into
everything the rest of the chart needs: openclaw's `agents.entries`, the
top-level `bindings` list, the workspace each agent's files belong in, and the
files themselves.

A directory is an agent if and only if it contains `agent.yaml` -- an explicit
marker beats guessing from whatever else happens to be in there, and it gives a
place to put per-agent config next to the prompt content it belongs with.

Cached on .Values for the same reason `asi.secrets` is: Helm renders each
template independently, and three of them need the identical answer. This
emits nothing; callers read `.Values.resolvedAgents`.
*/}}
{{- define "asi.agents" -}}
{{- if not (hasKey .Values "resolvedAgents") -}}
{{- $ids := list -}}
{{- $defs := dict -}}
{{- range $path, $_ := .Files.Glob "agents/*/agent.yaml" -}}
{{- $id := index (splitList "/" $path) 1 -}}
{{- $ids = append $ids $id -}}
{{- $raw := ($.Files.Get $path | fromYaml) | default dict -}}
{{/* fromYaml reports a parse failure as an "Error" key rather than failing. */}}
{{- if hasKey $raw "Error" -}}
{{- fail (printf "agents/%s/agent.yaml is not valid YAML: %v" $id (get $raw "Error")) -}}
{{- end -}}
{{- $_ := set $defs $id $raw -}}
{{- end -}}
{{- $ids = $ids | sortAlpha -}}
{{- $multi := gt (len $ids) 1 -}}
{{- $root := .Values.openclaw.agents.workspaceRoot -}}
{{- $entries := dict -}}
{{- $bindings := list -}}
{{- $files := dict -}}
{{- range $id := $ids -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9-]*$" $id) -}}
{{- fail (printf "agent directory %q is not a usable openclaw agent id -- use lowercase letters, digits and hyphens" $id) -}}
{{- end -}}
{{- $def := get $defs $id -}}
{{- $entry := (get $def "entry") | default dict -}}
{{/*
A sole agent owns the workspace root; in a fleet openclaw would give each agent
an id subdirectory of its own accord, but it is written out explicitly here
because the init container has to seed the very same path and the two agreeing
by construction beats the two agreeing by convention.
*/}}
{{- if not (hasKey $entry "workspace") -}}
{{- $_ := set $entry "workspace" (ternary (printf "%s/%s" $root $id) $root $multi) -}}
{{- end -}}
{{- $_ := set $entries $id $entry -}}
{{/*
Routing. With exactly one agent openclaw's sole-agent fallback delivers
everything to it and a binding would be noise. An explicit fleet is the
opposite: a surface with no matching binding *fails closed*, so a second agent
added without one stops the bot answering rather than picking a side. Refuse to
render instead.
*/}}
{{- $agentBindings := (get $def "bindings") | default list -}}
{{- if and $multi (not $agentBindings) -}}
{{- fail (printf "agent %q defines no bindings, and with %d agents configured openclaw has no sole-agent fallback -- a surface with no matching binding fails closed, so give %q a bindings entry in agents/%s/agent.yaml" $id (len $ids) $id $id) -}}
{{- end -}}
{{- range $binding := $agentBindings -}}
{{- $bindings = append $bindings (merge (dict "agentId" $id) $binding) -}}
{{- end -}}
{{- $agentFiles := list -}}
{{- range $path, $_ := $.Files.Glob (printf "agents/%s/*.md" $id) -}}
{{- $agentFiles = append $agentFiles $path -}}
{{- end -}}
{{- $_ := set $files $id ($agentFiles | sortAlpha) -}}
{{- end -}}
{{- $_ := set .Values "resolvedAgents" (dict
      "ids" $ids
      "multi" $multi
      "entries" $entries
      "bindings" $bindings
      "files" $files) -}}
{{- end -}}
{{- end -}}

{{/*
ConfigMap key for one definition file. Keys may not contain "/", so the agent
id is folded in with a separator and the volume's `items` maps it back to a
nested path at mount time.
*/}}
{{- define "asi.agents.key" -}}
{{- printf "%s--%s" (index (splitList "/" .path) 1) (base .path) -}}
{{- end -}}

{{/*
Fingerprint of the resolved credentials, for the pod annotations that decide
when a rotation has to roll a workload.
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
as the symlinks a Secret mount provides.
*/}}
{{- define "asi.credsMountPath" -}}/var/run/asi/creds{{- end -}}

{{/*
tmpfs handoff for the workspace fingerprint. The init container computes it and
the gateway's wrapper reads it back: a pod's env is fixed when the pod is
created, so a value that only exists once the volume is mounted cannot be
passed any other way.
*/}}
{{- define "asi.provenanceMountPath" -}}/var/run/asi/provenance{{- end -}}
