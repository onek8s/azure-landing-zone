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

# Promoted from Audit to Deny (design section 2.7: audit first, then deny, rule by rule; D82: as soon as a
# rule reports no violation): every rule here reported none, and the isolation tests' forbidden manifests check
# that each refuses. Still in Audit, with the reason (Azure Policy compliance, 2026-10-19):
#   k8s-pod-security-restricted      App Routing's gateway pods set no seccomp profile (AKS-managed)
#   k8s-deployment-safeguards        probes / seccomp / images of AKS-managed and upstream platform pods
#   k8s-allowed-images               ESO, external-dns and Flux images come from upstream registries
#   k8s-no-service-account-token-automount, h2c-upstream   1 non-compliant cluster each
#   k8s-image-integrity and the aks-* cluster settings      no Deny effect in their definitions (audit_only)
kubernetes_deny = [
  # The platform's own validations
  # 2026-10-19: app-egress replaces fqdn-egress (design D80) in deny - no application namespace of
  # aks-dev-int-stateless-az3 has a Cilium policy, and its one NetworkPolicy (AKS's
  # defaultnetworkpolicy) passed fqdn-egress's same NetworkPolicy rule (0 violations, Cluster status).
  "app-egress",
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
  # 2026-10-19 (D82): 0 non-compliant in Azure Policy's compliance of aks-dev-int-stateless-az3 (the cell
  # was stopped, so the add-on's last audit; nothing changes in a stopped cell). zone-placement: aks-hello
  # runs on int-se's zone nodes now; gateway-tls: traefik-dynamic states h2 and TLS 1.3 in every gateway
  # namespace.
  "zone-placement",
  "gateway-tls",
  # Built-in Kubernetes definitions
  "k8s-no-ingress",
  "k8s-read-only-root-filesystem",
  "k8s-internal-load-balancers", # 2026-10-19: an internal subscription (D52) has no public gateway
  # Built-in Azure resource definitions, 2026-10-19: 0 non-compliant (3 vaults, 1 registry)
  "key-vault-no-public-access",
  "acr-admin-disabled",
]
