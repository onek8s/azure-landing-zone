# The platform's own Kubernetes policies (OneK8s design section 2.7): custom Microsoft.Kubernetes.Data
# definitions with the Gatekeeper constraint and mutation templates of kubernetes/ embedded as
# Base64, assigned to the environment subscription like the built-ins in main.tf. The Azure Policy
# add-on of every cluster pulls them in within 15 minutes. kubernetes/test.sh tests the templates
# (gator, also in CI).
#
# The stateless cells and the stateful cluster share the subscription, and a Kubernetes definition's
# rule can test only a cluster's type, location and tags. So the assignments draw the line with
# not_scopes: the stateless rules leave out the stateful cluster (there is at most one, R9), the
# stateful rules leave out the stateless cells.
#
# Effects:
#   - new validations start as Audit, also when policy_enforcement_mode is Default (section 2.7:
#     audit in dev first, then deny), and are promoted to Deny one by one in var.kubernetes_deny -
#     once the clusters report no violation of them (aks-terraform's Cluster status lists them);
#   - the storage rules are enforced (Deny) in every mode: they replace the fleet's
#     ValidatingAdmissionPolicies, which already refused this, so moving them to the one policy
#     engine (R14) must not turn them into audit;
#   - the mutations are enforced in every mode: they only fill in what a pod leaves out and refuse
#     nothing, and R17's labels do not work without them.
locals {
  # Platform namespaces of the cluster and of aks-fluxcd-platform: left out of the application
  # rules. The zones' own `<zone>-gateway` and `<zone>-secrets` run on the system pool.
  kubernetes_excluded_namespaces = concat(local.platform_namespaces, [
    "kube-node-lease", "external-secrets", "external-dns", "platform-gateway", "infra-observability", "*-gateway", "*-secrets",
  ])

  # Namespaces AKS and its add-ons create, which carry no owner of their own: left out of the
  # namespace-ownership rule. Every other namespace - the applications' and the platform's own in
  # aks-fluxcd-platform - names its team, cost centre and contact.
  aks_namespaces = concat(local.platform_namespaces, ["kube-node-lease", "default", "app-routing-system"])

  cluster_ids = {
    for name in concat(var.stateless_cluster_names, [var.stateful_cluster_name]) :
    name => "/subscriptions/${var.subscription_id}/resourceGroups/${var.cluster_resource_group_name}/providers/Microsoft.ContainerService/managedClusters/${name}"
  }
  not_scopes = {
    all       = []
    stateless = [local.cluster_ids[var.stateful_cluster_name]]
    stateful  = [for name in var.stateless_cluster_names : local.cluster_ids[name]]
  }

  # The constraint templates: what they match, and the types of their parameters. A parameter added
  # to a template whose definition is already assigned needs a default (Azure refuses the update of
  # the definition otherwise): `defaults`.
  k8s_templates = {
    no-persistent-storage = { api_groups = ["", "storage.k8s.io"], kinds = ["Pod", "PersistentVolume", "PersistentVolumeClaim", "StorageClass"], parameters = {} }
    portable-storage-only = { api_groups = [""], kinds = ["Pod", "PersistentVolumeClaim"], parameters = { storageClassName = "String" } }
    zone-placement        = { api_groups = [""], kinds = ["Pod", "Namespace"], parameters = { zones = "Array" } }
    placement-labels      = { api_groups = [""], kinds = ["Pod"], parameters = { allowedArchitectures = "Array", allowedCapacities = "Array", allowedAccelerators = "Array" }, defaults = { allowedAccelerators = [] } }
    app-egress            = { api_groups = ["", "cilium.io", "networking.k8s.io"], kinds = ["Pod", "CiliumNetworkPolicy", "NetworkPolicy"], parameters = {} }
    gateway-only          = { api_groups = ["", "gateway.networking.k8s.io"], kinds = ["Service", "Gateway", "HTTPRoute"], parameters = { zones = "Array", domainSuffix = "String" } }
    secrets-via-eso       = { api_groups = [""], kinds = ["Secret"], parameters = { zones = "Array", exemptUsers = "Array" } }
    eso-objects           = { api_groups = ["external-secrets.io"], kinds = ["SecretStore", "ExternalSecret", "PushSecret"], parameters = { zones = "Array", keyVaultNamePrefix = "String", serviceAccount = "String" } }
    service-accounts      = { api_groups = [""], kinds = ["Pod", "ServiceAccount"], parameters = { readerServiceAccount = "String" } }
    h2c-upstream          = { api_groups = [""], kinds = ["Service"], parameters = { allowedAppProtocols = "Array", exemptServices = "Array" }, defaults = { exemptServices = [] } }
    gateway-tls           = { api_groups = [""], kinds = ["ConfigMap"], parameters = { configMapName = "String", dataKey = "String", alpnProtocols = "Array", minVersion = "String" } }
    rollout-guardrails = {
      api_groups = ["apps", "autoscaling", "policy"]
      kinds      = ["Deployment", "StatefulSet", "HorizontalPodAutoscaler", "PodDisruptionBudget"]
      parameters = { minReplicas = "Integer", spreadTopologyKey = "String", requireNoUnavailable = "Boolean" }
    }
    vertical-pod-autoscalers = { api_groups = ["autoscaling.k8s.io"], kinds = ["VerticalPodAutoscaler"], parameters = { allowedModes = "Array" } }
    namespace-ownership      = { api_groups = [""], kinds = ["Namespace"], parameters = { requiredLabels = "Array", requiredAnnotations = "Array" } }
  }

  # The zone rules about secrets also cover the zones' gateway namespaces (their certificates come
  # through ESO like an application's secrets); the operators' own `<zone>-secrets` stay out.
  kubernetes_excluded_namespaces_with_gateways = [for ns in local.kubernetes_excluded_namespaces : ns if ns != "*-gateway"]

  # The namespace's identity: the service account aks-terraform federates for its vault share.
  key_vault_service_account = "key-vault"

  k8s_validations = {
    no-persistent-storage = {
      display     = "Stateless clusters: no StorageClass, PersistentVolume, PersistentVolumeClaim, csi or ephemeral volume"
      template    = "no-persistent-storage"
      clusters    = "stateless"
      excluded    = ["kube-system"]
      values      = {}
      always_deny = true
    }
    portable-storage-only = {
      display     = "Clusters with storage: claims only on the portable StorageClass, no inline csi volumes"
      template    = "portable-storage-only"
      clusters    = "stateful"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { storageClassName = "portable-disk" }
      always_deny = true
    }
    zone-placement = {
      display     = "Isolation zones: zone namespaces carry their label, their pods run on the zone's nodes only"
      template    = "zone-placement"
      clusters    = "all"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { zones = var.isolation_zones }
      always_deny = false
    }
    placement-labels = {
      display     = "Stateless clusters: architecture, spot and GPUs only through the platform/arch, /capacity and /accelerator labels"
      template    = "placement-labels"
      clusters    = "stateless"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedArchitectures = ["amd64", "arm64", "multi"], allowedCapacities = ["on-demand", "spot"], allowedAccelerators = ["nvidia-gpu"] }
      always_deny = false
    }
    placement-labels-stateful = {
      display     = "Stateful cluster: amd64 on-demand only, no GPUs"
      template    = "placement-labels"
      clusters    = "stateful"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedArchitectures = ["amd64"], allowedCapacities = ["on-demand"], allowedAccelerators = [] }
      always_deny = false
    }
    app-egress = {
      display     = "Application network policies only inside the cluster (endpoints and Services, layers 3 and 4); pods use the cluster DNS"
      template    = "app-egress"
      clusters    = "all"
      excluded    = local.kubernetes_excluded_namespaces
      values      = {}
      always_deny = false
    }
    gateway-only = {
      display     = "Stateless clusters: applications published only through their zone's HTTPS Gateway"
      template    = "gateway-only"
      clusters    = "stateless"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { zones = var.isolation_zones, domainSuffix = var.zone_domain_suffix }
      always_deny = false
    }
    secrets-via-eso = {
      display  = "Isolation zones: only the zone's External Secrets Operator writes Secrets in its namespaces"
      template = "secrets-via-eso"
      clusters = "all"
      excluded = local.kubernetes_excluded_namespaces_with_gateways
      values = {
        zones = var.isolation_zones
        # The AKS Flux extension keeps its configuration's -auth, -genkey and -protected-parameters
        # Secrets in the team's namespace (aks-terraform's Cluster status lists who writes each).
        # aksService: AKS's control plane rewrites every Secret when it changes the KMS encryption
        # (KMS data encryption's secret migration failed with ReconcileAzureKeyVaultKmsError until it
        # was exempt, seen on az3 2026-10-15) - it never brings a value of its own.
        exemptUsers = [
          "system:serviceaccount:flux-system:fluxconfig-agent-sa",
          "system:serviceaccount:flux-system:fluxconfig-controller-sa",
          "aksService",
        ]
      }
      always_deny = false
    }
    eso-objects = {
      display  = "Isolation zones: External Secrets objects read only the namespace's own share of its zone's or the platform vault"
      template = "eso-objects"
      clusters = "all"
      excluded = local.kubernetes_excluded_namespaces_with_gateways
      values = {
        zones              = var.isolation_zones
        keyVaultNamePrefix = var.key_vault_name_prefix
        serviceAccount     = local.key_vault_service_account
      }
      always_deny = false
    }
    service-accounts = {
      display     = "Application pods: not as the vault reader's service account, no image pull secrets"
      template    = "service-accounts"
      clusters    = "all"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { readerServiceAccount = local.key_vault_service_account }
      always_deny = false
    }
    gateway-tls = {
      # The gateways' TLS options read back (design D70, D71): HTTP/2 and TLS 1.3 only, the same on
      # every gateway. Matches only the gateway namespaces (the one place the ConfigMap lives), so the
      # exclusion list is the platform's without `*-gateway`.
      display     = "Stateless clusters: the zone gateways offer ALPN h2 and TLS 1.3 only (Traefik's default TLS options)"
      template    = "gateway-tls"
      clusters    = "stateless"
      excluded    = local.kubernetes_excluded_namespaces_with_gateways
      values      = { configMapName = "traefik-dynamic", dataKey = "dynamic.yaml", alpnProtocols = ["h2"], minVersion = "VersionTLS13" }
      always_deny = false
    }
    h2c-upstream = {
      # HTTP/2 from the gateway to the pod (design D69, D70): audit until the lab shows both hops (V28, V29).
      # Flux's webhook receiver is the one Service that stays HTTP/1.1 (GitHub's deliveries, D78): exempt
      # by name, so it holds even if flux-system ever leaves the excluded namespaces.
      display     = "Stateless clusters: application Service ports declare appProtocol kubernetes.io/h2c - no HTTP/1.1 from the gateway"
      template    = "h2c-upstream"
      clusters    = "stateless"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedAppProtocols = ["kubernetes.io/h2c"], exemptServices = ["flux-system/webhook-receiver"] }
      always_deny = false
    }
    rollout-guardrails = {
      display     = "Stateless clusters: at least 2 replicas spread over nodes, rollouts with maxUnavailable 0, PDBs that allow a drain"
      template    = "rollout-guardrails"
      clusters    = "stateless"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { minReplicas = 2, spreadTopologyKey = "kubernetes.io/hostname", requireNoUnavailable = true }
      always_deny = false
    }
    rollout-guardrails-stateful = {
      display     = "Stateful cluster: at least 3 replicas spread over availability zones, PDBs that allow a drain"
      template    = "rollout-guardrails"
      clusters    = "stateful"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { minReplicas = 3, spreadTopologyKey = "topology.kubernetes.io/zone", requireNoUnavailable = false }
      always_deny = false
    }
    vertical-pod-autoscalers = {
      display     = "Stateless clusters: VerticalPodAutoscalers in place or off, requests only, with maxAllowed"
      template    = "vertical-pod-autoscalers"
      clusters    = "stateless"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedModes = ["Off", "Initial", "InPlaceOrRecreate"] }
      always_deny = false
    }
    namespace-ownership = {
      display  = "Namespaces name their owning team, cost centre and contact"
      template = "namespace-ownership"
      clusters = "all"
      excluded = local.aks_namespaces
      values = {
        requiredLabels      = ["platform/team", "platform/cost-center"]
        requiredAnnotations = ["platform/contact"]
      }
      always_deny = false
    }
    vertical-pod-autoscalers-stateful = {
      display     = "Stateful cluster: VerticalPodAutoscalers recommend only (Off)"
      template    = "vertical-pod-autoscalers"
      clusters    = "stateful"
      excluded    = local.kubernetes_excluded_namespaces
      values      = { allowedModes = ["Off"] }
      always_deny = false
    }
  }

  # Deny for the storage rules (always) and for each validation promoted in var.kubernetes_deny.
  k8s_deny = { for k, v in local.k8s_validations : k => v.always_deny || contains(var.kubernetes_deny, k) }

  # One definition per mutation (Azure cannot parameterize them): the zone ones per zone.
  k8s_mutations = merge(
    { for pair in setproduct(var.isolation_zones, ["zone-node-selector", "zone-toleration"]) :
      "${pair[1]}-${pair[0]}" => {
        display = "Zone ${pair[0]}: ${pair[1] == "zone-node-selector" ? "pods select the zone's nodes" : "pods tolerate the zone's taint"}"
        content = templatefile("${path.module}/kubernetes/mutations/${pair[1]}.yaml.tftpl", { zone = pair[0] })
      }
    },
    {
      arch-amd64      = { display = "platform/arch amd64 (default): nodeSelector kubernetes.io/arch amd64", content = file("${path.module}/kubernetes/mutations/arch-amd64.yaml.tftpl") }
      arch-arm64      = { display = "platform/arch arm64: nodeSelector kubernetes.io/arch arm64", content = file("${path.module}/kubernetes/mutations/arch-arm64.yaml.tftpl") }
      spot-toleration = { display = "platform/capacity spot: the spot taint tolerated", content = file("${path.module}/kubernetes/mutations/spot-toleration.yaml.tftpl") }
      spot-affinity   = { display = "platform/capacity spot: spot nodes preferred", content = file("${path.module}/kubernetes/mutations/spot-affinity.yaml.tftpl") }
      gpu-toleration  = { display = "platform/accelerator nvidia-gpu: the GPU taint tolerated", content = file("${path.module}/kubernetes/mutations/gpu-toleration.yaml.tftpl") }
    },
  )

  cluster_rule = { field = "type", in = ["Microsoft.ContainerService/managedClusters"] }
}

resource "azurerm_policy_definition" "kubernetes" {
  # One definition per template; a template assigned twice (placement-labels) shares it.
  for_each = local.k8s_templates

  name         = "onek8s-k8s-${each.key}"
  display_name = "OneK8s: ${each.key}"
  description  = yamldecode(file("${path.module}/kubernetes/templates/${each.key}.yaml")).metadata.annotations.description
  policy_type  = "Custom"
  mode         = "Microsoft.Kubernetes.Data"
  metadata     = jsonencode({ category = "Kubernetes", version = "1.0.0", source = "onek8s/azure-landing-zone stacks/aks-policy/kubernetes" })

  parameters = jsonencode(merge({
    effect = {
      type          = "String"
      defaultValue  = "Audit"
      allowedValues = ["audit", "Audit", "deny", "Deny", "disabled", "Disabled"]
      metadata      = { displayName = "Effect" }
    }
    excludedNamespaces = {
      type         = "Array"
      defaultValue = ["kube-system", "gatekeeper-system", "azure-arc"]
      metadata     = { displayName = "Namespace exclusions" }
    }
    }, {
    # The constraint's own parameters
    for name, type in each.value.parameters : name => merge(
      { type = type, metadata = { displayName = name } },
      contains(keys(try(each.value.defaults, {})), name) ? { defaultValue = each.value.defaults[name] } : {},
    )
  }))

  policy_rule = jsonencode({
    if = local.cluster_rule
    then = {
      effect = "[parameters('effect')]"
      details = {
        templateInfo = {
          sourceType = "Base64Encoded"
          content    = filebase64("${path.module}/kubernetes/templates/${each.key}.yaml")
        }
        apiGroups          = each.value.api_groups
        kinds              = each.value.kinds
        excludedNamespaces = "[parameters('excludedNamespaces')]"
        values             = { for name, _ in each.value.parameters : name => "[parameters('${name}')]" }
      }
    }
  })
}

resource "azurerm_policy_definition" "kubernetes_mutation" {
  for_each = local.k8s_mutations

  name         = "onek8s-k8s-${each.key}"
  display_name = "OneK8s: ${each.value.display}"
  policy_type  = "Custom"
  mode         = "Microsoft.Kubernetes.Data"
  metadata     = jsonencode({ category = "Kubernetes", version = "1.0.0", source = "onek8s/azure-landing-zone stacks/aks-policy/kubernetes/mutations" })

  parameters = jsonencode(merge({
    effect = {
      type          = "String"
      defaultValue  = "Mutate"
      allowedValues = ["mutate", "Mutate", "disabled", "Disabled"]
      metadata      = { displayName = "Effect" }
    }
  }))

  policy_rule = jsonencode({
    if = local.cluster_rule
    then = {
      effect = "[parameters('effect')]"
      details = {
        mutationInfo = {
          sourceType = "Base64Encoded"
          content    = base64encode(each.value.content)
        }
      }
    }
  })
}

resource "azurerm_subscription_policy_assignment" "kubernetes" {
  for_each             = local.k8s_validations
  name                 = "aks-${local.env}-k8s-${each.key}"
  display_name         = "AKS ${local.env}: ${each.value.display}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = azurerm_policy_definition.kubernetes[each.value.template].id
  not_scopes           = local.not_scopes[each.value.clusters]
  enforce              = local.k8s_deny[each.key] || local.enforce
  location             = var.location
  parameters = jsonencode(merge({
    effect             = { value = local.k8s_deny[each.key] ? "Deny" : "Audit" }
    excludedNamespaces = { value = each.value.excluded }
  }, { for name, value in each.value.values : name => { value = value } }))

  lifecycle {
    precondition {
      condition     = alltrue([for k in var.kubernetes_deny : contains(keys(local.k8s_validations), k) || contains(keys(local.policy_assignments), k)])
      error_message = "kubernetes_deny names a rule that is neither a platform validation nor a built-in assignment: ${join(", ", setsubtract(var.kubernetes_deny, concat(keys(local.k8s_validations), keys(local.policy_assignments))))}."
    }
    precondition {
      condition     = length(setintersection(var.kubernetes_deny, local.audit_only)) == 0
      error_message = "kubernetes_deny names a built-in whose definition has no Deny effect (Audit or Disabled only): ${join(", ", setintersection(var.kubernetes_deny, local.audit_only))}."
    }
  }
}

resource "azurerm_subscription_policy_assignment" "kubernetes_mutation" {
  for_each             = local.k8s_mutations
  name                 = "aks-${local.env}-k8s-${each.key}"
  display_name         = "AKS ${local.env}: ${each.value.display}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = azurerm_policy_definition.kubernetes_mutation[each.key].id
  enforce              = true
  location             = var.location
  parameters = jsonencode({
    effect = { value = "Mutate" }
  })
}
