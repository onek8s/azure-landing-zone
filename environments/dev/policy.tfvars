# AKS policy assignments of dev (OneK8s design section 2.7), stacks/aks-policy
environment     = "dev"
location        = "germanywestcentral"
subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev

# Internal and external workloads have a subscription and clusters each (design decision D52).
# sub-aks-dev plays sub-aks-dev-int since 2026-10-15: its clusters hold the internal zones only, so the zone
# policies know only those - a namespace or pod naming an external zone is refused here. Both countries are
# enabled; the lab's one cell, az3, runs Sweden's int-se.
exposure        = "int"
isolation_zones = ["int-fi", "int-se"]

# DoNotEnforce until phase 3 (acceptance testing), then Default – together with policy_enforcement_mode in
# accelerator/config/platform-landing-zone.tfvars
policy_enforcement_mode = "DoNotEnforce"

# The environment's container registry: created by onek8s/aks-terraform (shared/envs/dev.tfvars)
container_registry_name = "acronek8sdev"

# The environment's Key Vaults, <prefix>-<zone> and <prefix>-platform (onek8s/aks-terraform shared/envs/dev.tfvars).
# kv-onek8s-gwc since the move to germanywestcentral: the old kv-onek8s-dev-platform is soft-deleted with purge
# protection in swedencentral until 2027-01, and a vault cannot be recovered into another region.
key_vault_name_prefix = "kv-onek8s-gwc"

# The platform's own Kubernetes policies (stacks/aks-policy/kubernetes.tf): the zones' domain and which
# clusters are stateless or stateful, as onek8s/aks-terraform names them (envs/*.tfvars)
zone_domain_suffix          = "dev.onek8s.lol"
cluster_resource_group_name = "rg-aks-dev"
stateless_cluster_names     = ["aks-dev-int-stateless-az3"]
stateful_cluster_name       = "aks-dev-int-stateful"

# Promoted from Audit to Deny (design section 2.7: audit first, then deny, rule by rule): every rule
# here reported no violation on aks-dev-stateless-az1 (2026-10-13, Cluster status, constraints audited
# after the new rules were applied), and the isolation tests' forbidden manifests check that each now
# refuses. Still in Audit, with the reason:
#   zone-placement                   aks-hello's lab cost exception (system pool) is reported by design
#   k8s-pod-security-restricted      App Routing's gateway pods set no seccomp profile (AKS-managed)
#   k8s-deployment-safeguards        probes / seccomp / images of AKS-managed and upstream platform pods
#   k8s-allowed-images               ESO, external-dns and Flux images come from upstream registries
#   k8s-no-service-account-token-automount, k8s-internal-load-balancers (the external zones' gateways
#   are public by design), k8s-image-integrity (preview, audit only)
kubernetes_deny = [
  # The platform's own validations
  "fqdn-egress",
  "gateway-only",
  "placement-labels",
  "placement-labels-stateful",
  "secrets-via-eso",
  "eso-objects",
  "service-accounts",
  "rollout-guardrails",
  "rollout-guardrails-stateful",
  "vertical-pod-autoscalers",
  "vertical-pod-autoscalers-stateful",
  # 2026-10-13: every namespace of aks-dev-stateless-az1 names its team, cost centre and contact (0
  # violations); the isolation tests' namespace does too.
  "namespace-ownership",
  # Built-in Kubernetes definitions
  "k8s-no-ingress",
  "k8s-read-only-root-filesystem",
]
