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

{{- define "asi.secretName" -}}
{{- default (printf "%s-secrets" (include "asi.fullname" .)) .Values.secrets.name -}}
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
