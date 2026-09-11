KUBE_CONTEXT?=k3d-halo-dev
KUBE_NAMESPACE?=asi-dev

# Supplied, not generated: `make deploy` pipes this into the chart on stdin and
# `make secrets-rotate` leaves it alone. Sourced from .envrc.
OPENCLAW_PROVIDER_API_KEY?=${OPENAI_API_KEY}

# Jaeger is a separate release in a separate namespace, so trace history
# survives `make nuke` on KUBE_NAMESPACE. Same cluster, same context.
JAEGER_NAMESPACE?=observability
