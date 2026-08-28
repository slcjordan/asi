KUBE_CONTEXT?=k3d-asi-dev
KUBE_NAMESPACE?=asi-dev

# Supplied, not generated: `make deploy` pipes this into the chart on stdin and
# `make secrets-rotate` leaves it alone. Sourced from .envrc.
OPENCLAW_PROVIDER_API_KEY?=${OPENAI_API_KEY}
