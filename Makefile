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

KUBECTL := kubectl --context $(KUBE_CONTEXT) --namespace $(KUBE_NAMESPACE)
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
	@echo "generation: $(CURRENT_GENERATION)"

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

.PHONY: secrets-rotate
secrets-rotate: ## re-derive every generated credential and roll both workloads
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
.PHONY: restart-openclaw
restart-openclaw: ## roll openclaw only -- use this when the bot is stuck on openclaw_
	@$(KUBECTL) rollout restart statefulset/$(RELEASE)-openclaw
	@$(KUBECTL) rollout status statefulset/$(RELEASE)-openclaw

# Ordered rather than simultaneous: openclaw restarted alongside a
# still-restarting ergo just spends its first few seconds on ECONNREFUSED and
# a reconnect backoff.
.PHONY: restart
restart: restart-ergo restart-openclaw ## roll both workloads, ergo first

.PHONY: logs-ergo
logs-ergo: ## tail ergo logs
	@$(KUBECTL) logs --follow statefulset/$(RELEASE)-ergo

.PHONY: logs-openclaw
logs-openclaw: ## tail openclaw logs
	@$(KUBECTL) logs --follow statefulset/$(RELEASE)-openclaw

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
provenance: ## show the workspace fingerprint on current spans, and every snapshot recorded
	@echo "attributes on spans from the running pod:"
	@$(KUBECTL) exec statefulset/$(RELEASE)-openclaw -c openclaw -- \
		sh -c 'tr "," "\n" < /var/run/asi/provenance/attrs | sed "s/^/  /"'
	@echo
	@echo "snapshots (newest first) -- pass one to \`make provenance-show SNAPSHOT=...\`:"
	@$(KUBECTL) exec statefulset/$(RELEASE)-openclaw -c openclaw -- \
		$(PROVENANCE_GIT) log --format='  %H  %ad  %s' --date=iso refs/heads/provenance

# The point of recording a hash: turn it back into the contents. With no FILE
# this lists the snapshot's files; with one it prints that file as it was.
.PHONY: provenance-show
provenance-show: ## recover a snapshot -- make provenance-show SNAPSHOT=<sha> [FILE=SOUL.md]
	@test -n "$(SNAPSHOT)" \
		|| { echo "set SNAPSHOT=<sha> (see \`make provenance\`)"; exit 1; }
ifeq ($(FILE),)
	@$(KUBECTL) exec statefulset/$(RELEASE)-openclaw -c openclaw -- \
		$(PROVENANCE_GIT) ls-tree -r --name-only $(SNAPSHOT)
else
	@$(KUBECTL) exec statefulset/$(RELEASE)-openclaw -c openclaw -- \
		$(PROVENANCE_GIT) show $(SNAPSHOT):$(FILE)
endif

# What actually changed between two workspace states.
.PHONY: provenance-diff
provenance-diff: ## diff two snapshots -- make provenance-diff FROM=<sha> TO=<sha>
	@test -n "$(FROM)" -a -n "$(TO)" \
		|| { echo "set FROM=<sha> TO=<sha> (see \`make provenance\`)"; exit 1; }
	@$(KUBECTL) exec statefulset/$(RELEASE)-openclaw -c openclaw -- \
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

.PHONY: gateway
gateway: ## forward the openclaw control UI to localhost:18789
	@echo "gateway token:"
	@$(KUBECTL) get secret $(SECRET_NAME) \
		--output jsonpath='{.data.openclaw-gateway-token}' | base64 -d; echo
	@$(KUBECTL) port-forward service/$(RELEASE)-openclaw 18789:18789

.PHONY: destroy
destroy: ## uninstall the release, keeping the secret and the volumes
	@$(HELM) uninstall $(RELEASE)

.PHONY: nuke
nuke: ## delete the namespace outright -- credentials and volumes included
	@$(KUBECTL) delete namespace $(KUBE_NAMESPACE) --ignore-not-found
