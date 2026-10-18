# Azure Policy for the AKS platform (OneK8s design section 2.7), assigned to the environment subscription so that a
# new or rebuilt cluster gets every policy automatically. A stack of its own: assignments are control plane only, so
# it runs on GitHub-hosted runners and applies whether or not the self-hosted runners and the AKS dev workflow are
# up – the clusters of onek8s/aks-terraform report their compliance to these assignments. Built-in definitions
# here; the platform's own Microsoft.Kubernetes.Data definitions (storage, zone pinning, architecture and spot,
# FQDN egress, Gateway API only, NAP NodePools) and mutations in kubernetes.tf, tested with gator
# (kubernetes/test.sh).
#
# Build tenant: every assignment uses var.policy_enforcement_mode (DoNotEnforce = audit only, section 7.1).
# New definitions start with effect Audit regardless of the enforcement mode (section 2.7: audit in dev first, then
# deny), so switching policy_enforcement_mode to Default does not turn them into Deny by accident.
locals {
  env     = var.environment
  enforce = var.policy_enforcement_mode == "Default"

  # Platform namespaces, left out of the application rules (section 2.7)
  # aks-command: `az aks command invoke`'s pod, the break-glass path into a private cluster
  # dapr-system: the AKS Dapr extension's control plane, a lab trial on aks-terraform's az3 (design D65)
  platform_namespaces = ["kube-system", "gatekeeper-system", "azure-arc", "azure-extensions-usage-system", "flux-system", "kube-public", "aks-istio-system", "aks-command", "dapr-system"]

  # Images by digest from the environment's ACR only
  allowed_images_regex = "^${var.container_registry_name}\\.azurecr\\.io/[^@]+@sha256:[a-f0-9]{64}$"

  policy_assignments = {
    # Kubernetes (Azure Policy add-on / Gatekeeper)
    k8s-pod-security-restricted = {
      id          = "/providers/Microsoft.Authorization/policySetDefinitions/42b8ef37-b724-4e24-bbc8-7a7708edfe00"
      description = "Kubernetes pod security restricted standards for Linux workloads"
      parameters = {
        effect             = { value = local.enforce ? "Deny" : "Audit" }
        excludedNamespaces = { value = local.platform_namespaces }
      }
    }
    k8s-allowed-images = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/febd0533-8e55-448f-b837-bd0e06f16469"
      description = "Images by digest from the environment's ACR only"
      parameters = {
        effect                      = { value = local.enforce ? "Deny" : "Audit" }
        allowedContainerImagesRegex = { value = local.allowed_images_regex }
        excludedNamespaces          = { value = ["kube-system", "gatekeeper-system", "azure-arc", "azure-extensions-usage-system", "flux-system"] }
      }
    }
    # Audit only until promoted to Deny (section 2.7)
    k8s-deployment-safeguards = {
      id          = "/providers/Microsoft.Authorization/policySetDefinitions/c047ea8e-9c78-49b2-958b-37e56d291a44"
      description = "Deployment safeguards: probes, resource requests and AKS best practices"
      parameters = {
        effect                      = { value = "Audit" }
        excludedNamespaces          = { value = local.platform_namespaces }
        allowedContainerImagesRegex = { value = local.allowed_images_regex }
        # What AKS itself passes when it turns deployment safeguards on: its own identities may edit
        # nodes, and its labels and system-pool taint are reserved.
        allowedUsers   = { value = ["nodeclient", "system:serviceaccount:kube-system:aci-connector-linux", "system:serviceaccount:kube-system:node-controller", "acsService", "aksService", "system:serviceaccount:kube-system:cloud-node-manager"] }
        allowedGroups  = { value = ["system:nodes"] }
        labels         = { value = ["kubernetes.azure.com"] }
        reservedTaints = { value = ["CriticalAddonsOnly"] }
      }
    }
    k8s-read-only-root-filesystem = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/df49d893-a74c-421d-bc95-c663042e5b80"
      description = "readOnlyRootFilesystem for application containers"
      parameters = {
        effect = { value = "Audit" }
        # An application rule: the platform's own pods (App Routing's gateways, the operators) stay
        # out, as in the platform's validations - AKS shapes the gateway pods, not this platform.
        excludedNamespaces = { value = local.kubernetes_excluded_namespaces }
      }
    }
    k8s-no-service-account-token-automount = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/423dd1ba-798e-40e4-9c4d-b6902674b423"
      description = "automountServiceAccountToken false for application pods"
      parameters = {
        effect             = { value = "Audit" }
        excludedNamespaces = { value = local.platform_namespaces }
      }
    }
    k8s-no-ingress = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/b81f454c-eebb-4e4f-9dfe-dca060e8a8fd"
      description = "No Ingress objects, Gateway API only"
      parameters = {
        effect             = { value = "Audit" }
        excludedNamespaces = { value = local.platform_namespaces }
        namespaces         = { value = [] } # every namespace but the excluded ones
        kind               = { value = "Ingress" }
        apiGroups          = { value = ["networking.k8s.io"] }
      }
    }
    k8s-internal-load-balancers = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/3fc4dc25-5baf-40d8-9b05-7fe74c1bc64e"
      description = "LoadBalancer Services only internal"
      parameters = {
        effect             = { value = "Audit" }
        excludedNamespaces = { value = local.platform_namespaces }
      }
    }
    k8s-image-integrity = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/cf426bb8-b320-4321-8545-1b784a5df3a4"
      description = "Images signed by the platform's certificate, checked by Image Integrity (Ratify) at admission (preview, audit only)"
      parameters = {
        effect             = { value = "Audit" }
        excludedNamespaces = { value = local.platform_namespaces }
      }
    }
    aks-ssh-disabled = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/28257686-e9db-403e-b9e2-a5eecbe03da9"
      description = "SSH access to the nodes disabled"
      parameters  = { effect = { value = "Audit" } }
    }
    aks-azure-cni = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/46238e2f-3f6f-4589-9f3f-77bed4116e67"
      description = "Azure CNI (Cilium dataplane)"
      parameters  = { effect = { value = "Audit" } }
    }
    aks-workload-identity = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/2cc2e023-0dac-4046-875b-178f683929d5"
      description = "Workload identity enabled (section 2.5)"
      parameters  = { effect = { value = "Audit" } }
    }
    # Cluster resources
    aks-azure-policy-add-on = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/0a15ec92-a229-4763-bb14-0ea34a568f8d"
      description = "Azure Policy add-on installed on every cluster"
      parameters  = { effect = { value = "Audit" } }
    }
    aks-private-cluster = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/040732e8-d947-40b8-95d6-854c95024bf8"
      description = "Private API server"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    aks-local-accounts-disabled = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/993c2fcd-2b29-49d2-9eb0-df2c3a730c32"
      description = "Entra ID only, no local accounts"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    aks-encryption-at-host = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/41425d9f-d1a5-499a-9932-f8ed8453932c"
      description = "Encryption at host on every node (section 4.2)"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    aks-cmk-disks = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/7d7be79c-23ba-4033-84dd-45e2a5ccdd67"
      description = "OS and data disks with customer-managed keys (section 4.2)"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    # Key Vault and ACR
    key-vault-purge-protection = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/0b60c0b2-2dc2-4e1c-b5c9-abbed971de53"
      description = "Purge protection on every vault"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    key-vault-no-public-access = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/405c5871-3e91-4644-8a63-58e19d68ff5b"
      description = "No public network access to Key Vault"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
    acr-admin-disabled = {
      id          = "/providers/Microsoft.Authorization/policyDefinitions/dc921057-6b28-4fbe-9b83-f7bec05db6c2"
      description = "No ACR admin user"
      parameters  = { effect = { value = local.enforce ? "Deny" : "Audit" } }
    }
  }
}

resource "azurerm_subscription_policy_assignment" "aks" {
  for_each             = local.policy_assignments
  name                 = "aks-${local.env}-${each.key}"
  display_name         = "AKS ${local.env}: ${each.value.description}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = each.value.id
  enforce              = local.enforce || contains(var.kubernetes_deny, each.key)
  parameters           = jsonencode(merge(each.value.parameters, contains(var.kubernetes_deny, each.key) ? { effect = { value = "Deny" } } : {}))
  location             = var.location

  # Not for the Kubernetes (Microsoft.Kubernetes.Data) definitions: Azure refuses a non-compliance
  # message on them.
  dynamic "non_compliance_message" {
    for_each = startswith(each.key, "k8s-") ? [] : [each.value.description]
    content {
      content = "Violates the AKS platform design (OneK8s design section 2.7): ${non_compliance_message.value}."
    }
  }
}
