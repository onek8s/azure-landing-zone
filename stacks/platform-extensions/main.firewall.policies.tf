# The Firewall Policies of OneK8s design decision D53: one parent policy (the platform's FQDNs, threat
# intelligence, IDPS and the guard rails between the exposures) and a child policy per exposure (its cells,
# vaults, registry and the zones' allow-lists), Premium. Built in every network mode: a policy needs no
# firewall, and one associated with none (or one) costs nothing, so the lab's `sandbox` mode keeps the
# rules reviewable in the Azure portal (Firewall Manager > Azure Firewall Policies) until `firewall` mode
# associates each exposure's hub Firewall with its child policy (V22). TLS inspection is not configured:
# it needs an intermediate CA in a Key Vault and the policy's own identity.
#
# Azure evaluates a parent's rule collection groups before any of the child's, whatever their priority,
# and network rules before application rules. So a deny in the parent cannot be undone by a child's allow
# (a parent rule wins over a child's mistake), and the deny-all tail is the Firewall's own default deny,
# not a rule: an explicit deny-all in the parent would win over every allow of the children.
#
# Source and destination addresses are IP groups of the cells' real prefixes (onek8s/aks-terraform
# shared/envs/<env>.tfvars and cells.tf), never the VirtualNetwork service tag.
locals {
  firewall_policies = var.firewall_policies_enabled

  # "<env>-<exposure>" => the environment's spokes of that exposure
  firewall_spokes = !local.firewall_policies ? {} : merge([
    for exposure, e in var.firewall_exposures : {
      for env, s in e.environments : "${env}-${exposure}" => merge(s, { env = env, exposure = exposure, corporate = e.corporate })
    }
  ]...)

  # "<env>-<zone>" => the isolation zone's prefixes in every cell of its environment
  firewall_zones = merge([
    for key, s in local.firewall_spokes : {
      for zone, z in s.zones : "${s.env}-${zone}" => merge(z, { spoke = key, zone = zone })
    }
  ]...)

  firewall_all_cells = [for key, s in local.firewall_spokes : azurerm_ip_group.policy_cells[key].id]

  # Per application, what it may reach outside the landing zone (design section 5.2): one file per application namespace,
  # firewall-applications/<env>-<exposure>/<namespace>.yaml - written by the egress agent's pull requests
  # (onek8s/aks-ai-agents) from the flows the firewall denied, reviewed by the platform and security. The source
  # is the application's zone (its pods have addresses of the zone's pod subnet): the rule's name says whose it is.
  firewall_application_files = !local.firewall_policies ? [] : [
    for f in fileset("${path.module}/${var.firewall_applications_dir}", "*/*.yaml") : f if contains(keys(local.firewall_spokes), split("/", f)[0])
  ]
  firewall_applications = {
    for f in local.firewall_application_files : trimsuffix(f, ".yaml") => merge(
      { spoke = split("/", f)[0], namespace = trimsuffix(split("/", f)[1], ".yaml") },
      yamldecode(file("${path.module}/${var.firewall_applications_dir}/${f}"))
    )
  }
  # "<spoke>" => "<namespace>-<protocol>-<port>" => the application rule
  firewall_application_rules = {
    for key in keys(local.firewall_spokes) : key => merge([
      for app in values(local.firewall_applications) : {
        for pp in distinct([for e in app.egress : "${lower(try(e.protocol, "https"))}-${try(e.port, 443)}"]) : "${app.namespace}-${pp}" => {
          zone     = app.zone
          protocol = title(split("-", pp)[0])
          port     = tonumber(split("-", pp)[1])
          fqdns    = sort(distinct([for e in app.egress : lower(e.fqdn) if "${lower(try(e.protocol, "https"))}-${try(e.port, 443)}" == pp]))
        }
      } if app.spoke == key
    ]...)
  }

  # "<env>-<exposure>" => what its cells may never reach: the other exposures' cells, and the corporate network
  # unless the exposure has the corporate path
  firewall_guard_rails = {
    for key, s in local.firewall_spokes : key => concat(
      [for other, o in local.firewall_spokes : azurerm_ip_group.policy_cells[other].id if o.exposure != s.exposure],
      s.corporate ? [] : [azurerm_ip_group.policy_client[0].id],
    ) if !s.corporate || length([for o in values(local.firewall_spokes) : o if o.exposure != s.exposure]) > 0
  }
}

resource "azurerm_resource_group" "firewall_policies" {
  provider = azurerm.connectivity
  count    = local.firewall_policies ? 1 : 0
  name     = "rg-hub-fwpolicy-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_ip_group" "policy_management" {
  provider            = azurerm.connectivity
  count               = local.firewall_policies ? 1 : 0
  name                = "ipg-mgmt"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_policies[0].name
  cidrs               = concat([local.management.snet_runners, local.management.snet_jump], local.labfw_vpn_pool)
  tags                = var.tags
}

# The simulated corporate network: no exposure without `corporate` may reach it
resource "azurerm_ip_group" "policy_client" {
  provider            = azurerm.connectivity
  count               = local.firewall_policies ? 1 : 0
  name                = "ipg-client"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_policies[0].name
  cidrs               = [var.client_address_space]
  tags                = var.tags
}

# Every node subnet and load balancer subnet of an environment's cells of one exposure
resource "azurerm_ip_group" "policy_cells" {
  provider            = azurerm.connectivity
  for_each            = local.firewall_policies ? local.firewall_spokes : {}
  name                = "ipg-${each.key}-cells"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_policies[0].name
  cidrs               = concat(each.value.system_prefixes, flatten([for z in values(each.value.zones) : z.prefixes]))
  tags                = var.tags
}

# The system pools: Flux, the gateways, the External Secrets Operators and external-dns run there
resource "azurerm_ip_group" "policy_system" {
  provider            = azurerm.connectivity
  for_each            = local.firewall_policies ? local.firewall_spokes : {}
  name                = "ipg-${each.key}-system"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_policies[0].name
  cidrs               = each.value.system_prefixes
  tags                = var.tags
}

resource "azurerm_ip_group" "policy_zone" {
  provider            = azurerm.connectivity
  for_each            = local.firewall_policies ? local.firewall_zones : {}
  name                = "ipg-${each.key}"
  location            = var.location
  resource_group_name = azurerm_resource_group.firewall_policies[0].name
  cidrs               = each.value.prefixes
  tags                = var.tags
}

resource "azurerm_firewall_policy" "parent" {
  provider                 = azurerm.connectivity
  count                    = local.firewall_policies ? 1 : 0
  name                     = "afwp-hub-parent-${var.location}"
  resource_group_name      = azurerm_resource_group.firewall_policies[0].name
  location                 = var.location
  sku                      = "Premium"
  threat_intelligence_mode = "Deny"
  # SNAT (design D61): the firewall translates every allowed flow to a destination outside these ranges - to its
  # public address on the internet, to its own private address elsewhere (the corporate network) - so the cells'
  # addresses, 100.64.0.0/10 among them, never leave the landing zone. Null: Azure's IANA private ranges.
  private_ip_ranges = var.firewall_snat_private_ranges

  dns {
    proxy_enabled = true
  }

  intrusion_detection {
    mode = "Deny"
  }

  tags = var.tags
}

resource "azurerm_firewall_policy" "exposure" {
  provider                 = azurerm.connectivity
  for_each                 = local.firewall_policies ? var.firewall_exposures : {}
  name                     = "afwp-hub-${each.key}-${var.location}"
  resource_group_name      = azurerm_resource_group.firewall_policies[0].name
  location                 = var.location
  sku                      = "Premium"
  base_policy_id           = azurerm_firewall_policy.parent[0].id
  threat_intelligence_mode = "Deny"
  private_ip_ranges        = var.firewall_snat_private_ranges

  dns {
    proxy_enabled = true
  }

  intrusion_detection {
    mode = "Deny"
  }

  tags = var.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "parent_platform" {
  provider           = azurerm.connectivity
  count              = local.firewall_policies && length(local.firewall_spokes) > 0 ? 1 : 0
  name               = "rcg-platform"
  firewall_policy_id = azurerm_firewall_policy.parent[0].id
  priority           = 100

  # D53: no route between the exposures, and none from an exposure without the corporate path to the
  # corporate network. Here in the parent, so no child policy can allow it.
  dynamic "network_rule_collection" {
    for_each = length(local.firewall_guard_rails) > 0 ? [1] : []
    content {
      name     = "exposure-guard-rails"
      priority = 100
      action   = "Deny"

      dynamic "rule" {
        for_each = local.firewall_guard_rails
        content {
          name                  = "${rule.key}-isolation"
          protocols             = ["Any"]
          source_ip_groups      = [azurerm_ip_group.policy_cells[rule.key].id]
          destination_ip_groups = rule.value
          destination_ports     = ["*"]
        }
      }
    }
  }

  network_rule_collection {
    name     = "platform-network"
    priority = 200
    action   = "Allow"

    # The management network and the labfw VPN's clients (the GitHub-hosted runners among them) -> the hub's Azure
    # Monitor Private Link scope (main.monitor.private.tf): Log Analytics queries and ingestion without public access
    dynamic "rule" {
      for_each = local.monitor_private_link ? [1] : []
      content {
        name                  = "management-to-monitor-private-link"
        protocols             = ["TCP"]
        source_ip_groups      = [azurerm_ip_group.policy_management[0].id]
        destination_addresses = [local.management.snet_pe]
        destination_ports     = ["443"]
      }
    }

    # Workload identity token exchange: Entra ID has no Private Link for sign-in
    rule {
      name                  = "entra-id"
      protocols             = ["TCP"]
      source_ip_groups      = local.firewall_all_cells
      destination_addresses = ["AzureActiveDirectory"]
      destination_ports     = ["443"]
    }

    # Pods that call the API server go to its public address (the `kubernetes` Service's endpoint), with no SNI an
    # application rule could match. Lab: public API servers (aks-terraform's dev exception to design section 2.2);
    # a private API server is reached in its own VNet and needs no rule.
    rule {
      name                  = "aks-api-servers"
      protocols             = ["TCP"]
      source_ip_groups      = local.firewall_all_cells
      destination_addresses = ["AzureCloud.${var.service_tag_region}"]
      destination_ports     = ["443"]
    }
  }

  application_rule_collection {
    name     = "platform-fqdns"
    priority = 300
    action   = "Allow"

    # AKS's required FQDNs: the API server, MCR, packages, node images
    rule {
      name                  = "aks-required"
      source_ip_groups      = local.firewall_all_cells
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
      source_ip_groups = local.firewall_all_cells
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
      source_ip_groups = local.firewall_all_cells
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
      name              = "defender-for-containers"
      source_ip_groups  = local.firewall_all_cells
      destination_fqdns = ["*.cloud.defender.microsoft.com"]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # The GitOps extension (Flux) and external-dns on the system pools. github.com only while the fleet is
    # pulled from Git; with the OCI artifact in the environment ACR it goes.
    rule {
      name             = "gitops-and-arm"
      source_ip_groups = [for key, s in local.firewall_spokes : azurerm_ip_group.policy_system[key].id]
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

    # The platform's Helm charts and upstream images (aks-fluxcd-platform, aks-terraform gateways/): Flux's
    # source-controller on the system pools, the kubelets of every node (the collectors are DaemonSets)
    dynamic "rule" {
      for_each = length(var.platform_source_fqdns) > 0 ? [1] : []
      content {
        name              = "platform-sources"
        source_ip_groups  = local.firewall_all_cells
        destination_fqdns = var.platform_source_fqdns
        protocols {
          type = "Https"
          port = 443
        }
      }
    }
  }
}

# One rule collection group per environment in its exposure's child policy
resource "azurerm_firewall_policy_rule_collection_group" "exposure_environment" {
  provider           = azurerm.connectivity
  for_each           = local.firewall_policies ? local.firewall_spokes : {}
  name               = "rcg-aks-${each.value.env}"
  firewall_policy_id = azurerm_firewall_policy.exposure[each.value.exposure].id
  priority           = 300 + index(sort(keys(var.firewall_exposures[each.value.exposure].environments)), each.value.env) * 10

  # Runners and jump host -> the environment's private endpoints and entry points (smoke tests)
  network_rule_collection {
    name     = "${each.key}-network"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "management-to-cells"
      protocols             = ["TCP"]
      source_ip_groups      = [azurerm_ip_group.policy_management[0].id]
      destination_ip_groups = [azurerm_ip_group.policy_cells[each.key].id]
      destination_ports     = ["443"]
    }

    # The management network and the labfw VPN's clients (the deployment runners) -> the environment's private
    # endpoints (aks-terraform shared/ snet-shared-pe): vaults, registry, Foundry, the Terraform state - none of them
    # has public network access
    dynamic "rule" {
      for_each = length(each.value.shared_prefixes) > 0 ? [1] : []
      content {
        name                  = "management-to-private-endpoints"
        protocols             = ["TCP"]
        source_ip_groups      = [azurerm_ip_group.policy_management[0].id]
        destination_addresses = each.value.shared_prefixes
        destination_ports     = ["443"]
      }
    }

    # Ping from the management network (and the labfw VPN's clients) to the cells: the gateways' internal load
    # balancers answer it themselves; private endpoints never do (Private Link carries TCP and UDP only)
    rule {
      name                  = "management-ping-cells"
      protocols             = ["ICMP"]
      source_ip_groups      = [azurerm_ip_group.policy_management[0].id]
      destination_ip_groups = [azurerm_ip_group.policy_cells[each.key].id]
      destination_ports     = ["*"]
    }

    # The corporate network (the client VNet) -> the internal zones' gateways (their internal load balancers in
    # snet-<zone>-ilb), only in the exposure with the corporate path
    dynamic "rule" {
      for_each = each.value.corporate ? [1] : []
      content {
        name                  = "corporate-to-zones"
        protocols             = ["TCP"]
        source_ip_groups      = [azurerm_ip_group.policy_client[0].id]
        destination_ip_groups = [for zone in keys(each.value.zones) : azurerm_ip_group.policy_zone["${each.value.env}-${zone}"].id]
        destination_ports     = ["443"]
      }
    }
  }

  application_rule_collection {
    name     = "${each.key}-platform"
    priority = 200
    action   = "Allow"

    # The platform vault and every zone vault: the External Secrets Operators and Ratify on the system pool,
    # and the management network (runners, jump host, the labfw VPN's clients). Their private endpoints
    # (aks-terraform shared/ private_endpoints) are reached through the firewall like the public ones.
    rule {
      name             = "key-vaults"
      source_ip_groups = [azurerm_ip_group.policy_system[each.key].id, azurerm_ip_group.policy_management[0].id]
      destination_fqdns = [
        for v in concat([each.value.platform_key_vault], [for z in values(each.value.zones) : z.key_vault]) : "${v}.vault.azure.net"
      ]
      protocols {
        type = "Https"
        port = 443
      }
    }

    # Lab: public environment ACR (Basic, no dedicated data endpoint): the layers come from its storage accounts
    dynamic "rule" {
      for_each = each.value.container_registry == null ? [] : [each.value.container_registry]
      content {
        name              = "container-registry"
        source_ip_groups  = [azurerm_ip_group.policy_cells[each.key].id, azurerm_ip_group.policy_management[0].id]
        destination_fqdns = ["${rule.value}.azurecr.io", "${rule.value}.${var.location}.data.azurecr.io", "*.blob.core.windows.net"]
        protocols {
          type = "Https"
          port = 443
        }
      }
    }

    # The Grafana collectors run on every node (D48); an internal exposure uses its hub's private endpoint instead
    dynamic "rule" {
      for_each = length(each.value.observability_fqdns) > 0 ? [1] : []
      content {
        name              = "observability"
        source_ip_groups  = [azurerm_ip_group.policy_cells[each.key].id]
        destination_fqdns = each.value.observability_fqdns
        protocols {
          type = "Https"
          port = 443
        }
      }
    }
  }

  # Per-zone allow-lists: what the zone's applications may name in their FQDN egress policies
  # (aks-fluxcd-platform policy/egress-allow-lists.yaml, design section 5.1)
  dynamic "application_rule_collection" {
    for_each = anytrue([for z in values(each.value.zones) : length(z.fqdn_allow_list) > 0]) ? [1] : []
    content {
      name     = "${each.key}-zones"
      priority = 300
      action   = "Allow"
      dynamic "rule" {
        for_each = { for zone, z in each.value.zones : zone => z.fqdn_allow_list if length(z.fqdn_allow_list) > 0 }
        content {
          name              = "${rule.key}-allow-list"
          source_ip_groups  = [azurerm_ip_group.policy_zone["${each.value.env}-${rule.key}"].id]
          destination_fqdns = rule.value
          protocols {
            type = "Https"
            port = 443
          }
        }
      }
    }
  }

  # Per application (design D61): what each application of the environment may reach, from its zone, as its
  # firewall-applications/<spoke>/<namespace>.yaml says
  dynamic "application_rule_collection" {
    for_each = length(local.firewall_application_rules[each.key]) > 0 ? [1] : []
    content {
      name     = "${each.key}-applications"
      priority = 400
      action   = "Allow"
      dynamic "rule" {
        for_each = local.firewall_application_rules[each.key]
        content {
          name              = rule.key
          source_ip_groups  = [azurerm_ip_group.policy_zone["${each.value.env}-${rule.value.zone}"].id]
          destination_fqdns = rule.value.fqdns
          protocols {
            type = rule.value.protocol
            port = rule.value.port
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition = alltrue([
        for app in values(local.firewall_applications) : app.spoke != each.key || (
          contains(keys(each.value.zones), app.zone) && startswith(app.namespace, "${app.zone}-") && length(app.egress) > 0 &&
          alltrue([for e in app.egress : can(regex("^(\\*\\.)?([a-z0-9-]+\\.)+[a-z]{2,}$", lower(e.fqdn))) && contains(["https", "http"], lower(try(e.protocol, "https")))])
        )
      ])
      error_message = "Every firewall-applications/${each.key}/<namespace>.yaml names a zone of ${each.key}, a namespace <zone>-<app>, and at least one egress entry with an fqdn (a name, or *. and a name) and protocol https or http."
    }
  }

  # The parent's groups first: Azure refuses parallel writes within one policy hierarchy
  depends_on = [azurerm_firewall_policy_rule_collection_group.parent_platform, azurerm_firewall_policy_rule_collection_group.build_tenant]
}
