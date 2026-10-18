# Hub Firewall rules (OneK8s design sections 2.4, 3.1 and 5.1) in the ALZ policy of the Azure Firewall, only in network
# mode "firewall" (labfw mode: main.labfw.tf). The Firewall decides what a *zone* may reach; Cilium FQDN
# policies decide what an *application* may reach. Rules are written with zone prefixes from the address plan
# (IP groups), never with the VirtualNetwork service tag.
locals {
  github_fqdns = [
    "github.com",
    "*.github.com",
    "*.githubusercontent.com",
    "*.actions.githubusercontent.com",
    "ghcr.io",
    "*.ghcr.io",
    "*.pkg.github.com",
    "*.blob.core.windows.net", # Actions artifacts, caches and job logs (GitHub-owned storage accounts)
  ]
  tooling_fqdns = [
    "registry.terraform.io",
    "releases.hashicorp.com",
    "checkpoint-api.hashicorp.com",
    "management.azure.com",
    "login.microsoftonline.com",
    "graph.microsoft.com",
    "aka.ms",
    "azcliprod.blob.core.windows.net",
    "packages.microsoft.com",
    "dl.k8s.io",
    "cdn.dl.k8s.io",
    "get.helm.sh",
    "mcr.microsoft.com",
    "*.data.mcr.microsoft.com",
  ]
  ubuntu_fqdns = [
    "*.ubuntu.com",
    "*.archive.ubuntu.com",
    "security.ubuntu.com",
    "*.snapcraft.io",
  ]
}

resource "azurerm_resource_group" "firewall_ip_groups" {
  provider = azurerm.connectivity
  count    = local.azure_firewall ? 1 : 0
  name     = "rg-hub-ipgroups-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_ip_group" "management" {
  provider            = azurerm.connectivity
  count               = local.azure_firewall ? 1 : 0
  name                = "ipg-mgmt"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs               = [local.management.snet_runners, local.management.snet_jump]
  tags                = var.tags
}

resource "azurerm_ip_group" "client" {
  provider            = azurerm.connectivity
  count               = local.azure_firewall ? 1 : 0
  name                = "ipg-client"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs               = [var.client_address_space]
  tags                = var.tags
}

# The build tenant's own egress (runners, jump host, test clients): in the Azure Firewall's ALZ policy, or in labfw
# mode in the parent policy of main.firewall.policies.tf, which labfw enforces through its child policy
locals {
  build_tenant_rules  = local.azure_firewall || local.labfw
  build_tenant_policy = local.azure_firewall ? module.platform.firewall_policy_id : one(azurerm_firewall_policy.parent[*].id)
  ipg_management      = local.azure_firewall ? one(azurerm_ip_group.management[*].id) : one(azurerm_ip_group.policy_management[*].id)
  ipg_client          = local.azure_firewall ? one(azurerm_ip_group.client[*].id) : one(azurerm_ip_group.policy_client[*].id)
  # Every cell's snet-system: its private cluster's API server endpoint (aks-terraform D58)
  cell_api_server_prefixes = distinct(flatten([for s in values(local.firewall_spokes) : s.system_prefixes]))
}

resource "azurerm_firewall_policy_rule_collection_group" "build_tenant" {
  provider           = azurerm.connectivity
  count              = local.build_tenant_rules ? 1 : 0
  name               = "rcg-build-tenant"
  firewall_policy_id = local.build_tenant_policy
  priority           = 200

  # Network rules before application rules: within a rule collection group Azure requires DNAT, then network,
  # then application collections by priority ("Invalid rule priority" in the portal otherwise)
  network_rule_collection {
    name     = "management-network"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "entra-id"
      protocols             = ["TCP"]
      source_ip_groups      = [local.ipg_management, local.ipg_client]
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }

    # labfw VPN clients (agent and management machines outside Azure) -> every cluster's API server: the management
    # network's API server private endpoints and each cell's snet-system, which holds its private cluster's Private
    # Link endpoint (aks-terraform D58) - and the jump host
    dynamic "rule" {
      for_each = local.labfw_vpn ? [1] : []
      content {
        name                  = "management-vpn"
        protocols             = ["TCP"]
        source_addresses      = local.labfw_vpn_pool
        destination_addresses = concat([local.management.snet_aks_api_pe, local.management.snet_jump], local.cell_api_server_prefixes)
        destination_ports     = ["443"]
      }
    }

    # ... and SSH to the jump host only
    dynamic "rule" {
      for_each = local.labfw_vpn ? [1] : []
      content {
        name                  = "management-vpn-ssh"
        protocols             = ["TCP"]
        source_addresses      = local.labfw_vpn_pool
        destination_addresses = [local.management.snet_jump]
        destination_ports     = ["22"]
      }
    }
  }

  application_rule_collection {
    name     = "management-egress"
    priority = 200
    action   = "Allow"

    rule {
      name             = "runners-github"
      source_ip_groups = [local.ipg_management]
      destination_fqdns = concat(local.github_fqdns, [
        "${var.state_storage_account_name}.blob.core.windows.net",
      ], local.runner_registry_private ? [] : azurerm_container_registry.runners[*].login_server)
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "runners-and-jump-tooling"
      source_ip_groups  = [local.ipg_management]
      destination_fqdns = local.tooling_fqdns
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name              = "jump-and-clients-os-updates"
      source_ip_groups  = [local.ipg_management, local.ipg_client]
      destination_fqdns = local.ubuntu_fqdns
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Azure refuses parallel writes within one policy hierarchy
  depends_on = [azurerm_firewall_policy_rule_collection_group.parent_platform]
}

# One rule collection group per AKS environment
resource "azurerm_ip_group" "zone_frontend" {
  provider = azurerm.connectivity
  for_each = !local.azure_firewall ? {} : merge([for env, plan in module.address_plan : {
    for zone, z in plan.zones : "${env}-${zone}" => { env = env, cidrs = [z.frontend] }
  }]...)
  name                = "ipg-${each.key}-frontend"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs               = each.value.cidrs
  tags                = var.tags
}

resource "azurerm_ip_group" "zone_backend" {
  provider = azurerm.connectivity
  for_each = !local.azure_firewall ? {} : merge([for env, plan in module.address_plan : {
    for zone, z in plan.zones : "${env}-${zone}" => { env = env, cidrs = [z.backend] }
  }]...)
  name                = "ipg-${each.key}-backend"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs               = each.value.cidrs
  tags                = var.tags
}

resource "azurerm_ip_group" "environment" {
  provider            = azurerm.connectivity
  for_each            = local.azure_firewall ? module.address_plan : {}
  name                = "ipg-${each.key}-all"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs               = [each.value.environment_prefix]
  tags                = var.tags
}

# Control plane zones (system pools) of the stateless cells
resource "azurerm_ip_group" "control_planes" {
  provider            = azurerm.connectivity
  for_each            = local.azure_firewall ? module.address_plan : {}
  name                = "ipg-${each.key}-control-planes"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs               = [for s in ["sl-az1", "sl-az2", "sl-az3"] : each.value.control_plane[s]]
  tags                = var.tags
}

# Everything in the frontend network: stateless cells and internal entry points. The backend prefixes (stateful
# cluster) are not in it, so they get no Internet access apart from the Entra ID and Azure Policy exceptions.
resource "azurerm_ip_group" "frontend" {
  provider            = azurerm.connectivity
  for_each            = local.azure_firewall ? module.address_plan : {}
  name                = "ipg-${each.key}-frontend"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_ip_groups[0].name
  cidrs = concat(
    [for s in ["sl-az1", "sl-az2", "sl-az3"] : each.value.control_plane[s]],
    [for z in each.value.zones : z.frontend],
  )
  tags = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "aks" {
  provider           = azurerm.connectivity
  for_each           = local.azure_firewall ? module.address_plan : {}
  name               = "rcg-aks-${each.key}"
  firewall_policy_id = module.platform.firewall_policy_id
  priority           = 300 + index(keys(module.address_plan), each.key) * 10

  network_rule_collection {
    name     = "aks-${each.key}-network"
    priority = 100
    action   = "Allow"

    # Stateless zone X -> zone X PaaS private endpoints and stateful applications (same zone only, TLS)
    dynamic "rule" {
      for_each = each.value.zones
      content {
        name                  = "${rule.key}-frontend-to-backend"
        protocols             = ["TCP"]
        source_ip_groups      = [azurerm_ip_group.zone_frontend["${each.key}-${rule.key}"].id]
        destination_ip_groups = [azurerm_ip_group.zone_backend["${each.key}-${rule.key}"].id]
        destination_ports     = ["443", "1433", "5432", "5671", "6380"]
      }
    }

    # All nodes -> shared private endpoints in the backend spoke (ACR, platform and zone Key Vaults)
    rule {
      name                  = "nodes-to-shared-pe"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.environment[each.key].id]
      destination_addresses = [each.value.backend.control_plane.snet_shared_pe]
      destination_ports     = ["443"]
    }

    # Workload identity token exchange: Entra ID has no Private Link for sign-in (OneK8s design open questions)
    rule {
      name                  = "entra-id"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.environment[each.key].id]
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }

    # Runners and jump host -> private endpoints of the environment (Key Vault and ACR data plane, smoke tests)
    rule {
      name                  = "management-to-environment"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.management[0].id]
      destination_ip_groups = [azurerm_ip_group.environment[each.key].id]
      destination_ports     = ["443"]
    }

    # Corporate network (client VNet) -> internal entry points (NGINXaaS) of the int-* zones
    rule {
      name                  = "client-to-internal-entry-points"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.client[0].id]
      destination_addresses = [for z in each.value.edge.zones : z.prefix]
      destination_ports     = ["443"]
    }

    # Internal entry point of zone X -> the gateway of zone X in every cell. Network rule: no SNAT, so NGINX sees
    # the client address for client-IP affinity (OneK8s design section 3.1).
    dynamic "rule" {
      for_each = each.value.edge.zones
      content {
        name                  = "${rule.key}-edge-to-cells"
        protocols             = ["TCP"]
        source_addresses      = [rule.value.prefix]
        destination_addresses = [for s in ["sl-az1", "sl-az2", "sl-az3"] : each.value.zones[rule.key].slots[s]]
        destination_ports     = ["443"]
      }
    }
  }

  application_rule_collection {
    name     = "aks-${each.key}-platform"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "aks-required"
      source_ip_groups      = [azurerm_ip_group.frontend[each.key].id]
      destination_fqdn_tags = ["AzureKubernetesService"]
      protocols {
        type = "Https"
        port = 443
      }
      protocols {
        type = "Http"
        port = 80
      }
    }

    rule {
      name             = "azure-policy-add-on"
      source_ip_groups = [azurerm_ip_group.environment[each.key].id]
      destination_fqdns = [
        "data.policy.core.windows.net",
        "store.policy.core.windows.net",
        "dc.services.visualstudio.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name             = "azure-monitor"
      source_ip_groups = [azurerm_ip_group.frontend[each.key].id]
      destination_fqdns = [
        "*.ods.opinsights.azure.com",
        "*.oms.opinsights.azure.com",
        "*.monitoring.azure.com",
        "global.handler.control.monitor.azure.com",
        "${var.location}.handler.control.monitor.azure.com",
        "*.ingest.monitor.azure.com",
        "*.metrics.ingest.monitor.azure.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    rule {
      name             = "defender-for-containers"
      source_ip_groups = [azurerm_ip_group.frontend[each.key].id]
      destination_fqdns = [
        "*.cloud.defender.microsoft.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Lab: public environment ACR (no private endpoint). Without a dedicated data endpoint the image layers are
    # served from the registry's storage accounts.
    dynamic "rule" {
      for_each = var.environments[each.key].public_registry ? [1] : []
      content {
        name              = "public-registry"
        source_ip_groups  = [azurerm_ip_group.frontend[each.key].id, azurerm_ip_group.management[0].id]
        destination_fqdns = ["*.azurecr.io", "*.blob.core.windows.net"]
        protocols {
          type = "Https"
          port = 443
        }
      }
    }

    # GitOps extension (Flux) on the system pools of the stateless clusters (OneK8s design section 3.3). github.com
    # is only needed while the fleet is pulled from Git; with the OCI artifact in the environment ACR it is removed.
    rule {
      name             = "gitops-flux"
      source_ip_groups = [azurerm_ip_group.control_planes[each.key].id]
      destination_fqdns = [
        "${var.location}.dp.kubernetesconfiguration.azure.com",
        "management.azure.com",
        "login.microsoftonline.com",
        "${var.location}.login.microsoft.com",
        "mcr.microsoft.com",
        "*.data.mcr.microsoft.com",
        "github.com",
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }
  }

  # Per-zone allow-lists: the union of what the zone's applications declare in their FQDN egress policies
  dynamic "application_rule_collection" {
    for_each = length(var.environments[each.key].zone_fqdn_allow_lists) > 0 ? [1] : []
    content {
      name     = "aks-${each.key}-zones"
      priority = 300
      action   = "Allow"
      dynamic "rule" {
        for_each = var.environments[each.key].zone_fqdn_allow_lists
        content {
          name              = "${rule.key}-allow-list"
          source_ip_groups  = [azurerm_ip_group.zone_frontend["${each.key}-${rule.key}"].id]
          destination_fqdns = rule.value
          protocols {
            type = "Https"
            port = 443
          }
        }
      }
    }
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.build_tenant]
}
