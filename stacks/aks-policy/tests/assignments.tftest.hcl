# Plans the stack with a mocked provider (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}

variables {
  environment                 = "dev"
  location                    = "swedencentral"
  subscription_id             = "00000000-0000-0000-0000-000000000003"
  container_registry_name     = "acronek8sdev"
  zone_domain_suffix          = "dev.onek8s.lol"
  cluster_resource_group_name = "rg-aks-dev"
  stateless_cluster_names     = ["aks-dev-ext-stateless-az1", "aks-dev-ext-stateless-az2"]
  stateful_cluster_name       = "aks-dev-ext-stateful"
  key_vault_name_prefix       = "kv-onek8s-dev"
}

run "audit_in_the_build_tenant" {
  command = plan

  assert {
    condition     = alltrue([for a in azurerm_subscription_policy_assignment.aks : !a.enforce])
    error_message = "DoNotEnforce: no built-in assignment may enforce."
  }

  assert {
    condition = alltrue([
      for k, a in azurerm_subscription_policy_assignment.kubernetes :
      a.enforce == contains(["no-persistent-storage", "portable-storage-only"], k)
    ])
    error_message = "DoNotEnforce: of the platform's validations only the storage rules, which replaced enforced ValidatingAdmissionPolicies, enforce."
  }

  assert {
    condition = alltrue([
      for k, a in azurerm_subscription_policy_assignment.kubernetes :
      jsondecode(a.parameters).effect.value == (contains(["no-persistent-storage", "portable-storage-only"], k) ? "Deny" : "Audit")
    ])
    error_message = "The storage rules deny; every other platform validation audits."
  }
}

run "platform_kubernetes_policies" {
  command = plan

  assert {
    condition     = length(azurerm_policy_definition.kubernetes) == 14 && alltrue([for d in azurerm_policy_definition.kubernetes : d.mode == "Microsoft.Kubernetes.Data"])
    error_message = "One Microsoft.Kubernetes.Data definition per constraint template."
  }

  assert {
    condition = alltrue([
      for k, d in azurerm_policy_definition.kubernetes :
      base64decode(jsondecode(d.policy_rule).then.details.templateInfo.content) == file("kubernetes/templates/${k}.yaml")
    ])
    error_message = "Each definition embeds its template from kubernetes/templates unchanged."
  }

  assert {
    condition     = length(azurerm_policy_definition.kubernetes_mutation) == 13 && alltrue([for a in azurerm_subscription_policy_assignment.kubernetes_mutation : a.enforce && jsondecode(a.parameters).effect.value == "Mutate"])
    error_message = "Two mutations per zone and five for architecture, spot and GPU, all enforced."
  }

  assert {
    condition     = strcontains(base64decode(jsondecode(azurerm_policy_definition.kubernetes_mutation["zone-node-selector-int-se"].policy_rule).then.details.mutationInfo.content), "value: \"int-se\"")
    error_message = "The zone mutations are rendered per zone."
  }

  assert {
    condition = (
      azurerm_subscription_policy_assignment.kubernetes["no-persistent-storage"].not_scopes == tolist(["/subscriptions/00000000-0000-0000-0000-000000000003/resourceGroups/rg-aks-dev/providers/Microsoft.ContainerService/managedClusters/aks-dev-ext-stateful"]) &&
      length(azurerm_subscription_policy_assignment.kubernetes["portable-storage-only"].not_scopes) == 2 &&
      endswith(azurerm_subscription_policy_assignment.kubernetes["portable-storage-only"].not_scopes[0], "/managedClusters/aks-dev-ext-stateless-az1") &&
      length(coalesce(azurerm_subscription_policy_assignment.kubernetes["zone-placement"].not_scopes, [])) == 0
    )
    error_message = "Stateless rules leave out the stateful cluster, stateful rules the stateless cells, zone rules reach every cluster."
  }

  assert {
    condition     = alltrue([for d in azurerm_policy_definition.kubernetes : jsondecode(d.policy_rule).if.field == "type"])
    error_message = "A Kubernetes definition's rule may test only type, location and tags."
  }

  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.kubernetes["gateway-only"].parameters).domainSuffix.value == "dev.onek8s.lol"
    error_message = "Routes are held to the environment's zone domains."
  }

  assert {
    condition = alltrue([
      for k in ["zone-placement", "placement-labels", "app-egress", "gateway-only", "portable-storage-only"] :
      contains(jsondecode(azurerm_subscription_policy_assignment.kubernetes[k].parameters).excludedNamespaces.value, "*-gateway")
    ])
    error_message = "The application rules leave out the platform's namespaces, the zones' gateways and secrets included."
  }
}

run "new_definitions_stay_audit_when_enforced" {
  command = plan

  variables {
    policy_enforcement_mode = "Default"
  }

  assert {
    condition     = alltrue([for k in ["zone-placement", "placement-labels", "app-egress", "gateway-only"] : jsondecode(azurerm_subscription_policy_assignment.kubernetes[k].parameters).effect.value == "Audit"])
    error_message = "The platform's new validations keep effect Audit until promoted."
  }

  assert {
    condition = alltrue([
      for k in ["k8s-deployment-safeguards", "k8s-read-only-root-filesystem", "k8s-no-service-account-token-automount", "k8s-no-ingress", "k8s-internal-load-balancers", "k8s-image-integrity", "aks-ssh-disabled", "aks-azure-cni", "aks-workload-identity"] :
      jsondecode(azurerm_subscription_policy_assignment.aks[k].parameters).effect.value == "Audit"
    ])
    error_message = "Definitions not yet promoted keep effect Audit."
  }

  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.aks["k8s-allowed-images"].parameters).allowedContainerImagesRegex.value == "^acronek8sdev\\.azurecr\\.io/[^@]+@sha256:[a-f0-9]{64}$"
    error_message = "Images by digest from the environment's registry only."
  }
}

run "promoted_rules_deny" {
  command = plan

  variables {
    kubernetes_deny = ["gateway-only", "eso-objects", "k8s-no-ingress"]
  }

  assert {
    condition = alltrue([
      for k, a in azurerm_subscription_policy_assignment.kubernetes :
      a.enforce == contains(["no-persistent-storage", "portable-storage-only", "gateway-only", "eso-objects"], k) &&
      jsondecode(a.parameters).effect.value == (a.enforce ? "Deny" : "Audit")
    ])
    error_message = "A validation in kubernetes_deny denies and is enforced also with DoNotEnforce; the others still audit."
  }

  assert {
    condition = (
      azurerm_subscription_policy_assignment.aks["k8s-no-ingress"].enforce &&
      jsondecode(azurerm_subscription_policy_assignment.aks["k8s-no-ingress"].parameters).effect.value == "Deny" &&
      !azurerm_subscription_policy_assignment.aks["k8s-read-only-root-filesystem"].enforce &&
      jsondecode(azurerm_subscription_policy_assignment.aks["k8s-read-only-root-filesystem"].parameters).effect.value == "Audit"
    )
    error_message = "A built-in Kubernetes assignment in kubernetes_deny denies; the others keep their effect."
  }
}

run "unknown_rule_refused" {
  command = plan

  variables {
    kubernetes_deny = ["no-such-rule"]
  }

  expect_failures = [azurerm_subscription_policy_assignment.kubernetes]
}

run "new_rules_parameters" {
  command = plan

  assert {
    condition = (
      jsondecode(azurerm_subscription_policy_assignment.kubernetes["eso-objects"].parameters).keyVaultNamePrefix.value == "kv-onek8s-dev" &&
      contains(jsondecode(azurerm_subscription_policy_assignment.kubernetes["eso-objects"].parameters).excludedNamespaces.value, "*-secrets") &&
      !contains(jsondecode(azurerm_subscription_policy_assignment.kubernetes["secrets-via-eso"].parameters).excludedNamespaces.value, "*-gateway") &&
      contains(jsondecode(azurerm_subscription_policy_assignment.kubernetes["service-accounts"].parameters).excludedNamespaces.value, "*-gateway")
    )
    error_message = "The secret rules cover the zones' gateway namespaces, not the operators'; the application rules leave both out."
  }

  assert {
    condition = (
      jsondecode(azurerm_subscription_policy_assignment.kubernetes["rollout-guardrails"].parameters).minReplicas.value == 2 &&
      jsondecode(azurerm_subscription_policy_assignment.kubernetes["rollout-guardrails-stateful"].parameters).minReplicas.value == 3 &&
      length(azurerm_subscription_policy_assignment.kubernetes["rollout-guardrails-stateful"].not_scopes) == 2 &&
      jsondecode(azurerm_subscription_policy_assignment.kubernetes["vertical-pod-autoscalers-stateful"].parameters).allowedModes.value == ["Off"]
    )
    error_message = "Stateless and stateful guardrails get their own parameters and scopes."
  }
}

run "display_names_fit" {
  command = plan

  assert {
    condition = alltrue(concat(
      [for a in azurerm_subscription_policy_assignment.aks : length(a.display_name) <= 128],
      [for a in azurerm_subscription_policy_assignment.kubernetes : length(a.display_name) <= 128],
      [for a in azurerm_subscription_policy_assignment.kubernetes_mutation : length(a.display_name) <= 128],
    ))
    error_message = "Azure refuses an assignment display name longer than 128 characters (only at apply)."
  }
}

run "zones_of_another_exposure_refused" {
  command = plan
  variables {
    exposure        = "ext"
    isolation_zones = ["ext-fi", "int-fi"]
  }
  expect_failures = [var.exposure]
}

run "an_external_subscription_has_external_zones" {
  command = plan
  variables {
    exposure        = "ext"
    isolation_zones = ["ext-fi", "ext-se"]
  }
  assert {
    condition     = !contains(keys(azurerm_policy_definition.kubernetes_mutation), "zone-node-selector-int-fi") && contains(keys(azurerm_policy_definition.kubernetes_mutation), "zone-node-selector-ext-se")
    error_message = "An external subscription gets no internal zone's mutations."
  }
}

run "h2c_upstream_exempts_only_the_flux_webhook_receiver_and_the_api_server" {
  command = plan

  assert {
    condition     = jsondecode(azurerm_subscription_policy_assignment.kubernetes["h2c-upstream"].parameters).exemptServices.value == ["flux-system/webhook-receiver", "default/kubernetes"]
    error_message = "h2c-upstream should exempt Flux's webhook receiver (design D78) and the API server's Service by name, nothing else."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.kubernetes["h2c-upstream"].parameters).exemptServices.defaultValue == []
    error_message = "The new parameter needs a default, or Azure refuses the update of the assigned definition."
  }
}

run "purge_protection_only_in_production" {
  command = plan

  assert {
    condition     = !contains(keys(azurerm_subscription_policy_assignment.aks), "key-vault-purge-protection")
    error_message = "dev: no purge protection policy (production only)."
  }
}

run "purge_protection_in_production" {
  command = plan

  variables {
    environment = "prd"
  }

  assert {
    condition     = contains(keys(azurerm_subscription_policy_assignment.aks), "key-vault-purge-protection")
    error_message = "prd: purge protection on every vault."
  }
}

run "audit_only_built_ins_cannot_deny" {
  command = plan

  variables {
    kubernetes_deny = ["aks-private-cluster"]
  }

  expect_failures = [azurerm_subscription_policy_assignment.kubernetes]
}

run "audit_only_built_ins_audit_when_enforced" {
  command = plan

  variables {
    policy_enforcement_mode = "Default"
  }

  assert {
    condition = alltrue([
      for k in ["aks-private-cluster", "aks-local-accounts-disabled", "aks-encryption-at-host", "aks-cmk-disks", "aks-azure-policy-add-on"] :
      jsondecode(azurerm_subscription_policy_assignment.aks[k].parameters).effect.value == "Audit"
    ])
    error_message = "Definitions with only Audit or Disabled keep Audit when enforced."
  }
}

run "dev_promotions_plan" {
  command = plan

  variables {
    kubernetes_deny = ["app-egress", "gateway-only", "placement-labels", "placement-labels-stateful", "secrets-via-eso", "eso-objects", "service-accounts", "rollout-guardrails", "rollout-guardrails-stateful", "vertical-pod-autoscalers", "vertical-pod-autoscalers-stateful", "namespace-ownership", "zone-placement", "gateway-tls", "k8s-no-ingress", "k8s-read-only-root-filesystem", "k8s-internal-load-balancers", "key-vault-no-public-access", "acr-admin-disabled"]
  }

  assert {
    condition = alltrue([
      for k in ["key-vault-no-public-access", "acr-admin-disabled", "k8s-internal-load-balancers"] :
      azurerm_subscription_policy_assignment.aks[k].enforce && jsondecode(azurerm_subscription_policy_assignment.aks[k].parameters).effect.value == "Deny"
    ]) && alltrue([for k in ["zone-placement", "gateway-tls"] : jsondecode(azurerm_subscription_policy_assignment.kubernetes[k].parameters).effect.value == "Deny"])
    error_message = "dev's promoted rules deny (environments/dev/policy.tfvars)."
  }
}
