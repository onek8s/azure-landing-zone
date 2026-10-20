variable "environment" {
  type        = string
  description = "Environment name: dev, acc or prd."
  validation {
    condition     = contains(["dev", "acc", "prd"], var.environment)
    error_message = "dev, acc or prd."
  }
}

variable "location" {
  type        = string
  description = "Location of the assignments' managed identities and metadata."
}

variable "subscription_id" {
  type        = string
  description = "The environment subscription (sub-aks-<env>) the policies are assigned to."
}

variable "policy_enforcement_mode" {
  type        = string
  default     = "DoNotEnforce"
  description = "Enforcement of the AKS platform's policy assignments: DoNotEnforce (audit) in the build tenant until phase 3, then Default. Compliance is reported in both modes."
  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.policy_enforcement_mode)
    error_message = "Default or DoNotEnforce."
  }
}

variable "container_registry_name" {
  type        = string
  description = "The environment's container registry, for the allowed-images policy. Not part of the landing zone: onek8s/aks-terraform creates it with the clusters (shared/, container_registry_name)."
}

variable "exposure" {
  type        = string
  default     = null
  description = "The exposure of the subscription's clusters: int or ext (design decision D52 - internal and external workloads have a subscription and clusters each). Every isolation zone must be of it, so the zone policies of a subscription know only its own exposure's zones. Null checks nothing."
  validation {
    condition     = var.exposure == null || contains(["int", "ext"], coalesce(var.exposure, "-"))
    error_message = "int or ext."
  }
  validation {
    condition     = var.exposure == null || alltrue([for zone in var.isolation_zones : startswith(zone, "${coalesce(var.exposure, "-")}-")])
    error_message = "Every isolation zone must be of the subscription's exposure (design decision D52)."
  }
}

variable "isolation_zones" {
  type        = list(string)
  default     = ["int-fi", "int-se", "ext-fi", "ext-se"]
  description = "The isolation zones (design: requirements, \"Isolation zone\"), as onek8s/aks-terraform's shared/ isolation_zones names them. The zone policies and mutations of kubernetes.tf are made for each."
}

variable "zone_domain_suffix" {
  type        = string
  description = "The environment's domain: zone <zone> publishes its applications' names below <zone>.<zone_domain_suffix> (e.g. ext-fi.dev.onek8s.lol)."
}

variable "cluster_resource_group_name" {
  type        = string
  description = "The resource group of the environment's clusters (onek8s/aks-terraform envs/*.tfvars resource_group_name)."
}

variable "stateless_cluster_names" {
  type        = list(string)
  description = "The environment's stateless cells (onek8s/aks-terraform envs/*.tfvars name), left out of the stateful cluster's rules. A cell missing here gets the stateful rules too - stricter, never looser."
}

variable "stateful_cluster_name" {
  type        = string
  description = "The environment's stateful cluster (at most one, R19), left out of the stateless rules - whether it exists yet or not."
}

variable "key_vault_name_prefix" {
  type        = string
  description = "The environment's Key Vault names without their suffix: the zone vaults are <prefix>-<zone>, the platform vault <prefix>-platform (onek8s/aks-terraform shared/envs/*.tfvars). The ESO rules allow a zone's SecretStores these two only."
}

variable "kubernetes_deny" {
  type        = list(string)
  default     = []
  description = <<DESCRIPTION
The Kubernetes rules promoted from Audit to Deny (design section 2.7: audit first, then deny, rule by
rule), whatever policy_enforcement_mode says: keys of kubernetes.tf's validations (zone-placement,
eso-objects, ...) or of main.tf's built-in `k8s-*` assignments (k8s-no-ingress, ...). A rule goes
here only once every cluster of the environment reports no violation of it - aks-terraform's Cluster
status lists them per object - and the isolation tests then expect it to refuse.
DESCRIPTION
}
