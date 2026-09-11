ENV_DIR  := envs
ENV_LINK := include.mk

include $(ENV_LINK)

# GNU make remakes any included file, then re-execs itself -- so a missing
# include.mk self-heals to the dev instead of erroring on a fresh clone.
$(ENV_LINK):
	@ln -sf $(ENV_DIR)/dev.mk $@

env-%: $(ENV_DIR)/%.mk ## switch environments (e.g. `make env-dev`)
	@ln -sf "$<" "$(ENV_LINK)"
	@echo "env -> $*"

# Name of the selected env, available to other recipes.
ENV_NAME := $(basename $(notdir $(realpath $(ENV_LINK))))

CHART       := charts/asi
RELEASE     ?= asi
SECRET_NAME ?= $(RELEASE)-secrets

# Which gateway the per-gateway targets act on. The chart deploys a fleet --
# one StatefulSet, Service, ConfigMap pair and PVC per entry under `gateways`
# in values.yaml -- and every workload is named `$(RELEASE)-<gateway>`. `main`
# is the IRC-facing one and the only one a human normally wants, so it is the
# default; `make gateways` lists the rest.
GATEWAY ?= main
GATEWAY_NAME = $(RELEASE)-$(GATEWAY)

# Selects every gateway pod at once, for the targets that should not have to
# name them. Reading the label beats parsing values.yaml, and beats keeping a
# second list here that could fall out of step with the chart.
GATEWAY_SELECTOR := app.kubernetes.io/component=openclaw

KUBECTL := kubectl --context $(KUBE_CONTEXT) --namespace $(KUBE_NAMESPACE)
KUBECTL_JAEGER := kubectl --context $(KUBE_CONTEXT) --namespace $(JAEGER_NAMESPACE)
HELM    := helm --kube-context $(KUBE_CONTEXT) --namespace $(KUBE_NAMESPACE)

# openclaw runs a locally built image -- upstream plus the @openclaw/irc
# plugin. The chart is the source of truth for which image that is, so the
# coordinates are read back out of values.yaml rather than written down a
# second time here. The tag doubles as the upstream openclaw version to build
# against, since the image is that version with a plugin added.
DOCKERFILE       := images/openclaw/Dockerfile
OPENCLAW_IMAGE   := $(shell awk '/^openclaw:/{o=1} o && /^    repository:/{r=$$2} o && /^    tag:/{print r ":" $$2; exit}' $(CHART)/values.yaml)
OPENCLAW_VERSION := $(lastword $(subst :, ,$(OPENCLAW_IMAGE)))

# k3d clusters have no registry here, so the image is side-loaded into the
# nodes' containerd instead of pushed. Anything that is not a k3d context is
# assumed to pull from a registry. Empty for those.
K3D_CLUSTER := $(patsubst k3d-%,%,$(filter k3d-%,$(KUBE_CONTEXT)))

# Rotation counter, read back from the cluster rather than tracked in a file so
# there is no local state to drift. Deliberately recursive (`=`, not `:=`): it
# has to reflect the cluster at recipe time, not at parse time. Absent secret
# reads as 0, which is also the chart default, so the first deploy generates.
CURRENT_GENERATION = $(shell $(KUBECTL) get secret $(SECRET_NAME) \
	--output jsonpath='{.data.generation}' 2>/dev/null \
	| base64 -d 2>/dev/null | grep -E '^[0-9]+$$' || echo 0)

GENERATION ?= $(CURRENT_GENERATION)

.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help.
	@echo "Make Commands:"
	@echo "---"
	@echo
	@cat $(MAKEFILE_LIST) | grep '^[a-z].*:.*##' | sed 's/\(.*\):.*##\(.*\)/* `make \1`:\2/'

.PHONY: env
env: ## print the selected environment
	@echo "$(ENV_NAME)"

.PHONY: envs
envs: ## list available environments
	@ls $(ENV_DIR)/*.mk | xargs -n1 basename | sed 's/\.mk$$//'

.PHONY: context
context: ## print the kube context, namespace and secret generation in use
	@echo "context:    $(KUBE_CONTEXT)"
	@echo "namespace:  $(KUBE_NAMESPACE)"
	@echo "release:    $(RELEASE)"
	@echo "gateway:    $(GATEWAY)  (override with GATEWAY=<name>)"
	@echo "generation: $(CURRENT_GENERATION)"

# Rendered rather than read from the cluster, so it answers before the first
# deploy and answers with what the chart *would* create rather than with
# whatever happens to be running.
.PHONY: gateways
gateways: ## list the gateways the chart deploys
	@helm template $(RELEASE) $(CHART) --namespace $(KUBE_NAMESPACE) \
		| awk '/^kind: StatefulSet/{k=1} k && /asi\.dev\/gateway:/{print $$2; k=0}' \
		| sort -u

.PHONY: lint
lint: ## lint the chart
	helm lint $(CHART)

.PHONY: image
image: ## build the openclaw+irc image and make the cluster able to run it
	@test -n "$(OPENCLAW_IMAGE)" \
		|| { echo "could not read openclaw.image from $(CHART)/values.yaml"; exit 1; }
	docker build \
		--build-arg OPENCLAW_VERSION=$(OPENCLAW_VERSION) \
		$(if $(IRC_PLUGIN_VERSION),--build-arg IRC_PLUGIN_VERSION=$(IRC_PLUGIN_VERSION),) \
		--tag $(OPENCLAW_IMAGE) \
		--file $(DOCKERFILE) \
		$(dir $(DOCKERFILE))
ifeq ($(K3D_CLUSTER),)
	docker push $(OPENCLAW_IMAGE)
else
	k3d image import $(OPENCLAW_IMAGE) --cluster $(K3D_CLUSTER)
endif

.PHONY: image-show
image-show: ## print the image the chart asks for and whether it exists locally
	@echo "image:      $(OPENCLAW_IMAGE)"
	@echo "dockerfile: $(DOCKERFILE)"
	@docker image inspect $(OPENCLAW_IMAGE) --format 'built:      {{ .Created }}' 2>/dev/null \
		|| echo "built:      not present locally -- run \`make image\`"

# `lookup` returns nothing outside a live cluster, so every generated
# credential renders as a fresh random value here. Useful for reading the
# manifests, useless for diffing them.
.PHONY: template
template: ## render manifests locally (credentials render as throwaway randoms)
	@helm template $(RELEASE) $(CHART) --namespace $(KUBE_NAMESPACE)

# The provider API key goes in on stdin rather than as `--set`, so it never
# lands in argv where `ps` and the shell history can see it. Passing it empty
# is safe: the chart preserves whatever the cluster already holds.
define VALUES
secrets:
  generation: $(GENERATION)
openclaw:
  provider:
    apiKey: $(OPENCLAW_PROVIDER_API_KEY)
endef
export VALUES

.PHONY: deploy
deploy: ## install or upgrade the release (idempotent; preserves existing secrets)
	@echo "$$VALUES" | $(HELM) upgrade $(RELEASE) $(CHART) \
		--install \
		--create-namespace \
		--values -

# Every pod carries `checksum/secrets` over the whole resolved map, so this
# rolls the entire fleet -- ergo and every gateway -- however few credentials
# actually changed.
.PHONY: secrets-rotate
secrets-rotate: ## re-derive every generated credential and roll every workload
	@echo "rotating $(SECRET_NAME): generation $(CURRENT_GENERATION) -> $$(( $(CURRENT_GENERATION) + 1 ))"
	@$(MAKE) --no-print-directory deploy GENERATION=$$(( $(CURRENT_GENERATION) + 1 ))

.PHONY: secrets-show
secrets-show: ## print the live credentials
	@$(KUBECTL) get secret $(SECRET_NAME) \
		--output go-template='{{range $$k, $$v := .data}}{{$$k}}={{$$v | base64decode}}{{"\n"}}{{end}}'

.PHONY: oper
oper: ## print the ergo operator login
	@echo "/OPER admin $$($(KUBECTL) get secret $(SECRET_NAME) \
		--output jsonpath='{.data.irc-oper-password}' | base64 -d)"

.PHONY: status
status: ## show release and workload status
	@$(HELM) status $(RELEASE) 2>/dev/null | sed -n '1,8p' || true
	@$(KUBECTL) get statefulset,deployment,pod,pvc,svc

.PHONY: restart-ergo
restart-ergo: ## roll ergo only -- disconnects every client on the network
	@$(KUBECTL) rollout restart statefulset/$(RELEASE)-ergo
	@$(KUBECTL) rollout status statefulset/$(RELEASE)-ergo

# The fix when openclaw is connected but answering to `openclaw_`: a rolling
# restart is graceful, so the socket closes, ergo drops the stale session at
# once rather than waiting out idle-timeouts.disconnect, and the new pod gets
# the nick back. Leaves everyone else on the network connected.
.PHONY: restart-gateway
restart-gateway: ## roll one gateway -- GATEWAY=<name>; use this when the bot is stuck on openclaw_
	@$(KUBECTL) rollout restart statefulset/$(GATEWAY_NAME)
	@$(KUBECTL) rollout status statefulset/$(GATEWAY_NAME)

.PHONY: restart-gateways
restart-gateways: ## roll every gateway in the fleet
	@$(KUBECTL) rollout restart statefulset --selector $(GATEWAY_SELECTOR)
	@$(KUBECTL) rollout status statefulset/$(RELEASE)-main

# Ordered rather than simultaneous: a gateway restarted alongside a
# still-restarting ergo just spends its first few seconds on ECONNREFUSED and
# a reconnect backoff. Only `main` talks to ergo, but the A2A peers are worth
# rolling together so the fleet comes back from one known state.
.PHONY: restart
restart: restart-ergo restart-gateways ## roll every workload, ergo first

.PHONY: logs-ergo
logs-ergo: ## tail ergo logs
	@$(KUBECTL) logs --follow statefulset/$(RELEASE)-ergo

.PHONY: logs-gateway
logs-gateway: ## tail one gateway's logs -- GATEWAY=<name>
	@$(KUBECTL) logs --follow statefulset/$(GATEWAY_NAME)

# The collector's debug exporter writes what it receives to its own stdout, so
# this *is* the trace view -- there is no store behind it and nothing to query.
# Spans arrive in batches, so expect a beat between the tool call and the span.
.PHONY: logs-otel
logs-otel: ## tail the otel collector -- this is where exported spans show up
	@$(KUBECTL) logs --follow deployment/$(RELEASE)-otel-collector

# Trace ids, and what each trace contains. openclaw exports no run id, so the
# trace is what ties an exec or tool span to the run that spawned it; this is
# the grouping to reach for first.
.PHONY: traces
traces: ## summarize exported spans by trace id
	@$(KUBECTL) logs deployment/$(RELEASE)-otel-collector \
		| awk '/Trace ID +:/{t=$$NF} /^ +Name +:/{print t, $$NF}' \
		| sort | uniq -c \
		| awk '{printf "%-34s %-26s %s\n", $$2, $$3, $$1}' \
		| sort

# Tracks openclaw.otel.resource.workspace.store in values.yaml.
PROVENANCE_STORE ?= /var/lib/asi/provenance/store.git
PROVENANCE_GIT    = git --git-dir=$(PROVENANCE_STORE)

.PHONY: provenance
provenance: ## show one gateway's workspace fingerprint and snapshots -- GATEWAY=<name>
	@echo "attributes on spans from $(GATEWAY_NAME):"
	@$(KUBECTL) exec statefulset/$(GATEWAY_NAME) -c openclaw -- \
		sh -c 'tr "," "\n" < /var/run/asi/provenance/attrs | sed "s/^/  /"'
	@echo
	@echo "snapshots (newest first) -- pass one to \`make provenance-show SNAPSHOT=...\`:"
	@$(KUBECTL) exec statefulset/$(GATEWAY_NAME) -c openclaw -- \
		$(PROVENANCE_GIT) log --format='  %H  %ad  %s' --date=iso refs/heads/provenance

# The point of recording a hash: turn it back into the contents. With no FILE
# this lists the snapshot's files; with one it prints that file as it was.
.PHONY: provenance-show
provenance-show: ## recover a snapshot -- make provenance-show SNAPSHOT=<sha> [FILE=SOUL.md]
	@test -n "$(SNAPSHOT)" \
		|| { echo "set SNAPSHOT=<sha> (see \`make provenance\`)"; exit 1; }
ifeq ($(FILE),)
	@$(KUBECTL) exec statefulset/$(GATEWAY_NAME) -c openclaw -- \
		$(PROVENANCE_GIT) ls-tree -r --name-only $(SNAPSHOT)
else
	@$(KUBECTL) exec statefulset/$(GATEWAY_NAME) -c openclaw -- \
		$(PROVENANCE_GIT) show $(SNAPSHOT):$(FILE)
endif

# What actually changed between two workspace states.
.PHONY: provenance-diff
provenance-diff: ## diff two snapshots -- make provenance-diff FROM=<sha> TO=<sha>
	@test -n "$(FROM)" -a -n "$(TO)" \
		|| { echo "set FROM=<sha> TO=<sha> (see \`make provenance\`)"; exit 1; }
	@$(KUBECTL) exec statefulset/$(GATEWAY_NAME) -c openclaw -- \
		$(PROVENANCE_GIT) diff $(FROM) $(TO)

.PHONY: irc
irc: ## forward the ergo TLS listener to localhost:6697
	@printf '/connect -tls localhost 6697 %s\n\n' \
		"$$($(KUBECTL) get secret $(SECRET_NAME) \
			--output jsonpath='{.data.irc-server-password}' | base64 -d)"
	@echo "-tls is the part clients get wrong: no client infers TLS from the"
	@echo "port, and ergo's 6697 listener is TLS-only, so a plaintext attempt"
	@echo "is dropped mid-handshake -- which surfaces as an immediate"
	@echo "disconnect with no error. The certificate is self-signed, so leave"
	@echo "verification off (irssi: do not pass -tls_verify)."
	@echo
	@$(KUBECTL) port-forward service/$(RELEASE)-ergo 6697:6697

# One token per gateway, so this is a credential for $(GATEWAY) and nothing
# else. The A2A routes register with `auth: "plugin"` and are gated by the
# per-peer bearers instead, so this token has no part in traffic between
# gateways.
.PHONY: gateway
gateway: ## forward one gateway's control UI to localhost:18789 -- GATEWAY=<name>
	@echo "gateway token ($(GATEWAY)):"
	@$(KUBECTL) get secret $(SECRET_NAME) \
		--output jsonpath='{.data.openclaw-gateway-token-$(GATEWAY)}' | base64 -d; echo
	@$(KUBECTL) port-forward service/$(GATEWAY_NAME) 18789:18789

# The end-to-end test for the A2A edge, run from inside `main` exactly the way
# the agent runs it: pick a variant, read the bearer off tmpfs, dispatch one
# fire-and-forget SendMessage. Nothing comes back on that call by design, so
# this joins #poetry *before* dispatching and then watches for the poem, which
# is the only place it ever appears.
#
# A poem in the watch window means the whole path works: channel loaded, peer
# authenticated, binding matched, agent answered, and the agent's own
# message(action="send") reached IRC. Silence means one of those failed, and
# `make logs-gateway GATEWAY=poet-a` is the next stop. Exits non-zero on
# silence, so it is usable as a check and not just as a demo.
#
# All of it in node rather than curl plus shell: the image has node, a request
# body should not be assembled by pasting strings into JSON, and the watcher
# needs a socket anyway. The bearer goes in through the environment, not argv.
# Deliberately no single quotes anywhere in the script below -- it is embedded
# in single quotes to keep it clear of both make and shell expansion.
POEM_SUBJECT ?= A villanelle about a k3d cluster being rebuilt.
POEM_CTX     ?= make-poem
POEM_FOR     ?= $(USER)
POEM_WATCH   ?= 120

define POEM_WATCHER_JS
const [url, ctx, subject, who, watch] = process.argv.slice(-5);
const net = require("net"), fs = require("fs"), crypto = require("crypto");
const pass = fs.readFileSync("/var/run/asi/creds/irc-server-password", "utf8").trim();
const nick = "poem-watch";
let buf = "", started = false;
const s = net.connect(6667, "asi-ergo", () =>
  s.write("PASS " + pass + "\r\nNICK " + nick + "\r\nUSER " + nick + " 0 * :" + nick + "\r\n"));
s.on("data", (d) => {
  buf += d;
  const lines = buf.split("\r\n"); buf = lines.pop();
  for (const l of lines) {
    if (l.startsWith("PING")) { s.write("PONG" + l.slice(4) + "\r\n"); continue; }
    const p = l.split(" ");
    if (p[1] === "001") s.write("JOIN #poetry\r\n");
    if (p[1] === "JOIN" && l.indexOf(nick + "!") === 1 && !started) { started = true; begin(); }
    if (p[1] === "PRIVMSG" && p[2] === "#poetry") {
      console.log("<" + l.slice(1, l.indexOf("!")) + "> " + l.slice(l.indexOf(" :", 1) + 2));
      if (url) process.exit(0);
    }
  }
});
async function begin() {
  if (!url) { console.error("watching #poetry for " + watch + "s"); return; }
  const body = { jsonrpc: "2.0", id: "1", method: "SendMessage", params: {
    configuration: { returnImmediately: true },
    message: { messageId: crypto.randomUUID(), role: "ROLE_USER", contextId: ctx,
      parts: [{ text: "for " + who + ": " + subject }] } } };
  const r = await fetch(url, { method: "POST", body: JSON.stringify(body),
    headers: { "content-type": "application/json", authorization: "Bearer " + process.env.TOKEN } });
  const j = await r.json().catch(() => null);
  if (!j || j.error) { console.error("dispatch failed: " + JSON.stringify(j)); process.exit(1); }
  const id = j.result && j.result.task && j.result.task.id;
  console.error("dispatched task " + id + "; watching #poetry for " + watch + "s");
}
setTimeout(() => {
  if (!url) process.exit(0);
  console.error("no poem within " + watch + "s -- check: make logs-gateway GATEWAY=<poet>");
  process.exit(1);
}, Number(watch) * 1000);
endef

define POEM_SCRIPT
set -eu
CTX=$$1; SUBJECT=$$2; WHO=$$3; WATCH=$$4
eval "$$(/var/run/asi/bin/pick-poet-gateway "$$CTX")"
echo "context: $$CTX" >&2
echo "peer:    $$PEER" >&2
TOKEN=$$(cat "$$TOKEN_FILE") exec node -e '$(POEM_WATCHER_JS)' "$$URL" "$$CTX" "$$SUBJECT" "$$WHO" "$$WATCH"
endef
export POEM_SCRIPT

.PHONY: poem
poem: ## dispatch a poem request and watch #poetry for it -- POEM_SUBJECT=... POEM_CTX=... POEM_FOR=...
	@$(KUBECTL) exec statefulset/$(RELEASE)-main -c openclaw -- \
		sh -c "$$POEM_SCRIPT" _ "$(POEM_CTX)" "$(POEM_SUBJECT)" "$(POEM_FOR)" "$(POEM_WATCH)"

# The channel on its own, dispatching nothing -- for watching what the poets
# post in response to real requests coming through #asi.
.PHONY: poetry
poetry: ## tail #poetry -- POEM_WATCH=<seconds>
	@$(KUBECTL) exec statefulset/$(RELEASE)-main -c openclaw -- \
		node -e '$(POEM_WATCHER_JS)' "" "" "" "" "$(POEM_WATCH)"

# ---------------------------------------------------------------------------
# Jaeger
#
# Deliberately a separate release in a separate namespace, from the *upstream*
# chart rather than one of ours. Separate namespace because `make nuke` deletes
# this project's namespace and namespace deletion ignores
# `helm.sh/resource-policy: keep` -- trace history that dies with the app is
# barely better than the log window it replaced. Upstream chart because
# Jaeger v2 rides the OpenTelemetry Collector and its config format is still
# moving; that is work worth leaving to the people who make it.
#
# The only coupling to asi is `otelCollector.tracesEndpoint` in the chart's
# values, which is why this can be installed, upgraded and destroyed entirely
# on its own.
JAEGER_RELEASE ?= jaeger
JAEGER_CHART   ?= jaegertracing/jaeger
JAEGER_VERSION ?= 4.13.1
JAEGER_VALUES  ?= deploy/jaeger.values.yaml
JAEGER_REPO    ?= https://jaegertracing.github.io/helm-charts

HELM_JAEGER := helm --kube-context $(KUBE_CONTEXT) --namespace $(JAEGER_NAMESPACE)

.PHONY: jaeger-repo
jaeger-repo: ## add/refresh the upstream jaeger helm repo
	@helm repo add jaegertracing $(JAEGER_REPO) >/dev/null
	@helm repo update jaegertracing >/dev/null
	@echo "jaegertracing repo ready"

.PHONY: jaeger-deploy
jaeger-deploy: jaeger-repo ## install or upgrade jaeger in its own namespace
	@$(HELM_JAEGER) upgrade $(JAEGER_RELEASE) $(JAEGER_CHART) \
		--install \
		--create-namespace \
		--version $(JAEGER_VERSION) \
		--values $(JAEGER_VALUES)

# Renders what would be applied, and then hands the resulting Jaeger config to
# the Jaeger binary to check. The config is a full override of the image's
# built-in one, so a typo in it is a pod that crashloops after deploy rather
# than a template that fails to render -- this catches it beforehand.
.PHONY: jaeger-validate
jaeger-validate: jaeger-repo ## render jaeger and validate its config against the real binary
	@helm template $(JAEGER_RELEASE) $(JAEGER_CHART) --namespace $(JAEGER_NAMESPACE) \
		--version $(JAEGER_VERSION) --values $(JAEGER_VALUES) \
		| python3 -c 'import sys,yaml; \
		  [open("/tmp/jaeger-config.yaml","w").write(list(d["data"].values())[0]) \
		   for d in yaml.safe_load_all(sys.stdin) if d and d["kind"]=="ConfigMap"]'
	@docker run --rm -v /tmp/jaeger-config.yaml:/c.yaml:ro \
		jaegertracing/jaeger:$(shell awk '/^    tag:/{gsub(/"/,"",$$2); print $$2; exit}' $(JAEGER_VALUES)) \
		validate --config=file:/c.yaml >/dev/null 2>&1 \
		&& echo "jaeger config valid" \
		|| { echo "jaeger config INVALID -- run the validate by hand for the error"; exit 1; }

.PHONY: jaeger-status
jaeger-status: ## show the jaeger release and its workload
	@$(KUBECTL_JAEGER) get deployment,pod,pvc,svc 2>&1

.PHONY: logs-jaeger
logs-jaeger: ## tail jaeger logs
	@$(KUBECTL_JAEGER) logs --follow deployment/$(JAEGER_RELEASE)

.PHONY: jaeger
jaeger: ## forward the jaeger UI to localhost:16686
	@echo "Jaeger UI: http://localhost:16686"
	@echo "Traces are also still printed by the collector -- \`make traces\` for a quick look."
	@$(KUBECTL_JAEGER) port-forward service/$(JAEGER_RELEASE) 16686:16686

# Leaves the PVC behind: it carries `helm.sh/resource-policy: keep`, so the
# traces survive an uninstall and a later reinstall picks them back up.
.PHONY: jaeger-destroy
jaeger-destroy: ## uninstall jaeger, keeping the trace volume
	@$(HELM_JAEGER) uninstall $(JAEGER_RELEASE)

.PHONY: destroy
destroy: ## uninstall the release, keeping the secret and the volumes
	@$(HELM) uninstall $(RELEASE)

.PHONY: nuke
nuke: ## delete the namespace outright -- credentials and volumes included
	@$(KUBECTL) delete namespace $(KUBE_NAMESPACE) --ignore-not-found
