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
	@$(KUBECTL) get statefulset,pod,pvc,svc

.PHONY: restart
restart: ## roll both workloads
	@$(KUBECTL) rollout restart statefulset/$(RELEASE)-ergo statefulset/$(RELEASE)-openclaw
	@$(KUBECTL) rollout status statefulset/$(RELEASE)-ergo
	@$(KUBECTL) rollout status statefulset/$(RELEASE)-openclaw

.PHONY: logs-ergo
logs-ergo: ## tail ergo logs
	@$(KUBECTL) logs --follow statefulset/$(RELEASE)-ergo

.PHONY: logs-openclaw
logs-openclaw: ## tail openclaw logs
	@$(KUBECTL) logs --follow statefulset/$(RELEASE)-openclaw

.PHONY: irc
irc: ## forward the ergo TLS listener to localhost:6697
	@echo "connect to localhost:6697 (TLS, self-signed); server password:"
	@$(KUBECTL) get secret $(SECRET_NAME) \
		--output jsonpath='{.data.irc-server-password}' | base64 -d; echo
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
