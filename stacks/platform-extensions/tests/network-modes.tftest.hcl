# Plans the stack in both network modes with mocked providers (no Azure access needed): `terraform test`.
mock_provider "azurerm" {}
mock_provider "azurerm" {
  alias = "connectivity"
}
mock_provider "azurerm" {
  alias = "management"
}
mock_provider "azapi" {}
mock_provider "tls" {}
mock_provider "random" {}

variables {
  subscription_ids = {
    management   = "00000000-0000-0000-0000-000000000001"
    connectivity = "00000000-0000-0000-0000-000000000002"
  }
  environments = {
    dev = { subscription_id = "00000000-0000-0000-0000-000000000003" }
  }
  state_storage_account_name = "stoalzbuildswe1abcd"
  state_resource_group_name  = "rg-alz-build-state-swedencentral-1"
  state_container_name       = "build-tfstate"
  github_runner_token        = "github_pat_dummy"
}

override_data {
  target = module.platform.data.azurerm_subscription.connectivity
  values = {
    id              = "/subscriptions/00000000-0000-0000-0000-000000000002"
    subscription_id = "00000000-0000-0000-0000-000000000002"
  }
}

override_data {
  target = module.platform.data.azurerm_virtual_network.hub
  values = {
    id                  = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-swedencentral/providers/Microsoft.Network/virtualNetworks/vnet-hub-swedencentral"
    name                = "vnet-hub-swedencentral"
    resource_group_name = "rg-hub-swedencentral"
    address_space       = ["10.0.0.0/22"]
  }
}

override_data {
  target = module.platform.data.azurerm_firewall.hub
  values = {
    ip_configuration = [{ private_ip_address = "10.0.0.4", name = "default", subnet_id = "", public_ip_address_id = "" }]
  }
}

override_data {
  target = module.platform.data.azurerm_firewall_policy.hub
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-swedencentral/providers/Microsoft.Network/firewallPolicies/fwp-hub-swedencentral"
  }
}

override_data {
  target = module.platform.data.azurerm_resources.private_dns_zones
  values = {
    resources = [
      { name = "privatelink.vaultcore.azure.net", id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-dns-swedencentral/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net", type = "Microsoft.Network/privateDnsZones", location = "global", resource_group_name = "rg-hub-dns-swedencentral", tags = {} },
      { name = "int-fi.dev.example-test.com", id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-dns-swedencentral/providers/Microsoft.Network/privateDnsZones/int-fi.dev.example-test.com", type = "Microsoft.Network/privateDnsZones", location = "global", resource_group_name = "rg-hub-dns-swedencentral", tags = {} },
    ]
  }
}

override_data {
  target = module.platform.data.azurerm_private_dns_zone.hub
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-hub-dns-swedencentral/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }
}

override_data {
  target = data.azurerm_storage_account.state
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-alz-build-state-swedencentral-1/providers/Microsoft.Storage/storageAccounts/stoalzbuildswe1abcd"
  }
}

override_data {
  target = data.azurerm_subscription.environment
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000003"
  }
}

override_data {
  target = data.azurerm_subscription.management
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000001"
  }
}

run "firewall_mode" {
  command = plan

  variables {
    network_mode = "firewall"
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.aks) == 1 && length(azurerm_route_table.management) == 1 && length(azurerm_nat_gateway.management) == 0
    error_message = "firewall mode: Firewall rules and route tables, no NAT gateways."
  }

  assert {
    condition     = length(azurerm_container_group.runners) == 1 && tolist(azurerm_container_group.runners["01"].dns_config[0].nameservers)[0] == "10.0.0.4"
    error_message = "one runner resolving through the Firewall DNS proxy."
  }

  assert {
    condition     = length(azurerm_private_endpoint.runners_acr) == 0 && azurerm_container_registry.runners[0].public_network_access_enabled
    error_message = "lab: Basic runner registry without a private endpoint."
  }
}

run "sandbox_mode" {
  command = plan

  variables {
    network_mode = "sandbox"
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.aks) == 0 && length(azurerm_firewall_policy_rule_collection_group.build_tenant) == 0 && length(azurerm_ip_group.environment) == 0
    error_message = "sandbox mode creates no Firewall rules."
  }

  assert {
    condition     = length(azurerm_nat_gateway.management) == 1 && length(azurerm_nat_gateway.client) == 0 && length(azurerm_route_table.management) == 0 && length(azurerm_route_table.client) == 0
    error_message = "sandbox mode: NAT gateway instead of route tables, none for the client VNet without a test client."
  }

  assert {
    condition     = length(azurerm_linux_virtual_machine.jump) == 0 && length(azurerm_linux_virtual_machine.client) == 0
    error_message = "lab: no jump host and no test client by default."
  }

  assert {
    condition     = length(azurerm_role_assignment.aks_management_peering) == 1 && length(azurerm_role_assignment.aks_client_peering) == 1
    error_message = "sandbox mode lets the environment identity peer to the management and client VNets."
  }

  assert {
    condition     = length(azurerm_container_group.runners["01"].dns_config) == 0 && length(azurerm_virtual_network.management.dns_servers) == 0 && length(azurerm_private_dns_zone_virtual_network_link.hub_zones) == 2
    error_message = "sandbox mode resolves through Azure DNS with the management and client VNets linked to every hub private link zone, not to the other hub zones."
  }
}

run "sandbox_mode_design_options" {
  command = plan

  variables {
    network_mode        = "sandbox"
    client_vm_enabled   = true
    jump_host_enabled   = true
    runner_registry_sku = "Premium"
  }

  assert {
    condition     = length(azurerm_nat_gateway.client) == 1 && length(azurerm_linux_virtual_machine.client) == 1 && length(azurerm_linux_virtual_machine.jump) == 1
    error_message = "the test client brings its NAT gateway back."
  }

  assert {
    condition     = length(azurerm_private_endpoint.runners_acr) == 1 && !azurerm_container_registry.runners[0].public_network_access_enabled
    error_message = "Premium runner registry: private endpoint, no public access."
  }
}

run "sandbox_mode_without_runners" {
  command = plan

  variables {
    network_mode        = "sandbox"
    github_runner_token = ""
  }

  assert {
    condition     = length(azurerm_container_group.runners) == 0 && length(azurerm_nat_gateway.management) == 0 && length(azurerm_public_ip.management_nat) == 0
    error_message = "no runners and no jump host: no NAT gateway for the management VNet."
  }
  assert {
    condition     = length(azurerm_container_registry.runners) == 0 && length(azurerm_container_registry_task.runner_image) == 0 && length(azurerm_user_assigned_identity.runners) == 0
    error_message = "no runners: no runner registry, so the environment's registry is the only one."
  }
}

run "firewall_policies_without_firewall" {
  command = plan

  variables {
    network_mode = "sandbox"
    firewall_exposures = {
      ext = {
        environments = {
          dev = {
            system_prefixes     = ["172.21.0.0/24", "172.21.16.0/24"]
            platform_key_vault  = "kv-onek8s-dev-platform"
            container_registry  = "acronek8sdev"
            observability_fqdns = ["*.grafana.net"]
            zones = {
              ext-fi = { prefixes = ["172.21.3.0/24", "172.21.19.0/24"], key_vault = "kv-onek8s-dev-ext-fi", fqdn_allow_list = ["api.github.com"] }
              ext-se = { prefixes = ["172.21.4.0/24", "172.21.20.0/24"], key_vault = "kv-onek8s-dev-ext-se" }
            }
          }
        }
      }
    }
  }

  assert {
    condition     = length(azurerm_firewall_policy.parent) == 1 && azurerm_firewall_policy.parent[0].sku == "Premium" && keys(azurerm_firewall_policy.exposure) == ["ext"]
    error_message = "sandbox mode still builds the parent policy and the ext child policy."
  }

  assert {
    condition     = length(azurerm_ip_group.policy_cells["dev-ext"].cidrs) == 6 && toset(azurerm_ip_group.policy_zone["dev-ext-fi"].cidrs) == toset(["172.21.3.0/24", "172.21.19.0/24"])
    error_message = "IP groups of the cells' real prefixes."
  }

  assert {
    condition     = anytrue([for c in azurerm_firewall_policy_rule_collection_group.parent_platform[0].network_rule_collection : c.action == "Deny" && c.priority == 100])
    error_message = "the parent denies ext -> the corporate network."
  }

  assert {
    condition     = length([for c in azurerm_firewall_policy_rule_collection_group.exposure_environment["dev-ext"].application_rule_collection : c if c.name == "dev-ext-zones"]) == 1
    error_message = "a zone allow-list collection when a zone has an allow-list."
  }
}

run "firewall_rules_per_application" {
  command = plan

  variables {
    network_mode                 = "sandbox"
    firewall_applications_dir    = "tests/firewall-applications"
    firewall_snat_private_ranges = ["10.0.0.0/16", "172.16.0.0/12", "100.64.0.0/10"]
    firewall_exposures = {
      int = {
        corporate = true
        environments = {
          dev = {
            system_prefixes    = ["172.22.16.0/24", "100.64.0.0/20"]
            platform_key_vault = "kv-onek8s-gwc-platform"
            zones = {
              int-se = { prefixes = ["172.22.18.0/24", "100.64.32.0/20"], key_vault = "kv-onek8s-gwc-int-se" }
            }
          }
        }
      }
    }
  }

  assert {
    condition = (
      [for c in azurerm_firewall_policy_rule_collection_group.exposure_environment["dev-int"].application_rule_collection : c.priority if c.name == "dev-int-applications"] == [400] &&
      toset([for c in azurerm_firewall_policy_rule_collection_group.exposure_environment["dev-int"].application_rule_collection : c.rule[*].name if c.name == "dev-int-applications"][0]) == toset(["int-se-example-https-443", "int-se-example-http-80"])
    )
    error_message = "One application rule per application, protocol and port, in a collection of its own."
  }
  assert {
    condition = [
      for r in [for c in azurerm_firewall_policy_rule_collection_group.exposure_environment["dev-int"].application_rule_collection : c.rule if c.name == "dev-int-applications"][0] : r.destination_fqdns if r.name == "int-se-example-https-443"
    ][0] == tolist(["*.example.org", "api.open-meteo.com"])
    error_message = "The application's HTTPS destinations, sorted; files of other environments are ignored."
  }
  assert {
    condition     = tolist(azurerm_firewall_policy.parent[0].private_ip_ranges) == tolist(["10.0.0.0/16", "172.16.0.0/12", "100.64.0.0/10"]) && tolist(azurerm_firewall_policy.exposure["int"].private_ip_ranges) == tolist(["10.0.0.0/16", "172.16.0.0/12", "100.64.0.0/10"])
    error_message = "Both policies translate everything that leaves the landing zone's ranges."
  }
}

run "firewall_rules_per_application_refuse_a_namespace_of_another_zone" {
  command = plan

  variables {
    network_mode              = "sandbox"
    firewall_applications_dir = "tests/firewall-applications"
    firewall_exposures = {
      int = {
        environments = {
          dev = {
            system_prefixes    = ["100.64.0.0/20"]
            platform_key_vault = "kv-onek8s-gwc-platform"
            zones = {
              int-fi = { prefixes = ["100.64.16.0/20"], key_vault = "kv-onek8s-gwc-int-fi" }
            }
          }
        }
      }
    }
  }

  expect_failures = [azurerm_firewall_policy_rule_collection_group.exposure_environment]
}

run "firewall_policies_off" {
  command = plan

  variables {
    network_mode              = "sandbox"
    firewall_policies_enabled = false
  }

  assert {
    condition     = length(azurerm_firewall_policy.parent) == 0 && length(azurerm_firewall_policy.exposure) == 0 && length(azurerm_resource_group.firewall_policies) == 0
    error_message = "no policies when turned off."
  }
}

run "labfw_mode" {
  command = plan

  # The lab's settings (terraform.tfvars): the internal exposure's child policy, the spokes on labfw's DNS proxy
  variables {
    network_mode = "labfw"
  }

  assert {
    condition     = length(module.labfw) == 1 && module.labfw[0].private_ip == "10.0.1.4"
    error_message = "labfw mode deploys labfw at 10.0.1.4 in snet-labfw."
  }

  assert {
    condition     = [for r in azurerm_route_table.management[0].route : r.next_hop_in_ip_address] == ["10.0.1.4"] && [for r in azurerm_route_table.client[0].route : r.next_hop_in_ip_address] == ["10.0.1.4"]
    error_message = "the management and client VNets send 0.0.0.0/0 to labfw."
  }

  assert {
    condition     = alltrue([for p in ["10.0.0.0/22", "10.0.8.0/22", "10.200.0.0/22", "172.22.16.0/24", "172.22.17.0/24", "172.20.2.0/26"] : contains(module.labfw[0].dns_clients, p)])
    error_message = "labfw serves (DNS proxy, NSG) the hub, the management and client VNets and every cell of firewall_exposures."
  }

  assert {
    condition = (
      contains(module.labfw[0].dns_clients, "100.64.0.0/20") && contains(module.labfw[0].dns_clients, "100.64.32.0/20") &&
      output.labfw.log_analytics.table == "LabfwFirewallLog_CL"
    )
    error_message = "labfw serves the firewall-egress cell (100.64.0.0/16, D59) and ships its log of denied connections to Log Analytics."
  }

  assert {
    condition     = length(azurerm_nat_gateway.management) == 0 && length(azurerm_firewall_policy_rule_collection_group.aks) == 0 && length(azurerm_ip_group.environment) == 0
    error_message = "labfw mode: no NAT gateways and none of the Azure Firewall's ALZ policy rules."
  }

  assert {
    condition     = length(azurerm_firewall_policy_rule_collection_group.build_tenant) == 1
    error_message = "the build tenant's egress rules go into the parent policy that labfw enforces."
  }

  assert {
    condition = (
      length(azurerm_monitor_private_link_scope.hub) == 1 &&
      toset(keys(azurerm_monitor_private_link_scoped_service.hub)) == toset(["labfw-workspace", "labfw-endpoint", "workspace-log-dev-platform"]) &&
      length(azurerm_private_endpoint.monitor_private_link) == 1
    )
    error_message = "The hub's Azure Monitor Private Link scope holds labfw's workspace and endpoint and dev's workspace, with a private endpoint."
  }

  assert {
    condition = (
      contains([for r in one([for c in azurerm_firewall_policy_rule_collection_group.exposure_environment["dev-int"].network_rule_collection : c if c.name == "dev-int-network"]).rule : r.name], "management-to-private-endpoints") &&
      contains([for r in one([for c in azurerm_firewall_policy_rule_collection_group.parent_platform[0].network_rule_collection : c if c.name == "platform-network"]).rule : r.name], "management-to-monitor-private-link")
    )
    error_message = "The management network and the VPN's clients reach the environment's private endpoints and the Azure Monitor Private Link scope (no public network access)."
  }

  assert {
    condition     = tolist(azurerm_virtual_network.management.dns_servers) == tolist(["10.0.1.4"]) && length(azurerm_private_dns_zone_virtual_network_link.hub_zones) == 0
    error_message = "the lab's spokes resolve through labfw's DNS proxy, not through hub zone links of their own."
  }

  assert {
    condition     = length(azurerm_role_assignment.aks_management_peering) == 0 && length(azurerm_role_assignment.aks_client_peering) == 0 && length(azurerm_role_assignment.aks_hub_peering) == 1
    error_message = "the cells peer to the hub only, like in firewall mode."
  }

  assert {
    condition     = keys(azurerm_firewall_policy.exposure) == ["int"] && length([for c in azurerm_firewall_policy_rule_collection_group.exposure_environment["dev-int"].network_rule_collection : c if anytrue([for r in c.rule : r.name == "corporate-to-zones"])]) == 1
    error_message = "the internal exposure's child policy lets the corporate network reach its zones' gateways."
  }

  assert {
    condition     = anytrue([for c in azurerm_firewall_policy_rule_collection_group.parent_platform[0].network_rule_collection : anytrue([for r in c.rule : r.name == "aks-api-servers" && r.destination_addresses == tolist(["AzureCloud.germanywc"])])])
    error_message = "the cells reach the public API servers by the region's AzureCloud service tag."
  }

  assert {
    condition     = anytrue([for c in azurerm_firewall_policy_rule_collection_group.parent_platform[0].application_rule_collection : anytrue([for r in c.rule : r.name == "platform-sources"])])
    error_message = "the cells reach the platform's chart and image sources."
  }
}

run "labfw_mode_vpn_and_dns_proxy" {
  command = plan

  variables {
    network_mode = "labfw"
    labfw = {
      spoke_dns_proxy = true
      vpn = {
        enabled = true
        peers   = [{ name = "agent-1", public_key = "dGVzdHRlc3R0ZXN0dGVzdHRlc3R0ZXN0dGVzdHRlc3Q=", allowed_ips = ["10.0.12.10/32"] }]
      }
    }
    firewall_exposures = {
      ext = {
        environments = {
          dev = {
            system_prefixes    = ["172.21.0.0/24"]
            platform_key_vault = "kv-onek8s-dev-platform"
            zones = {
              ext-fi = { prefixes = ["172.21.3.0/24"], key_vault = "kv-onek8s-dev-ext-fi" }
            }
          }
        }
      }
    }
  }

  assert {
    condition     = module.labfw[0].vpn_pool == "10.0.12.0/24" && contains(azurerm_ip_group.policy_management[0].cidrs, "10.0.12.0/24")
    error_message = "the VPN client pool counts as management in the policies."
  }

  assert {
    condition = alltrue([
      for c in azurerm_firewall_policy_rule_collection_group.build_tenant[0].network_rule_collection : c.priority < min([for a in azurerm_firewall_policy_rule_collection_group.build_tenant[0].application_rule_collection : a.priority]...)
    ])
    error_message = "Azure requires a group's network rule collections before its application rule collections (smaller priority)."
  }

  assert {
    condition = alltrue([
      for r in one(azurerm_firewall_policy_rule_collection_group.build_tenant[0].network_rule_collection).rule :
      r.destination_ports == tolist(["443"]) && contains(r.destination_addresses, "172.21.0.0/24") if r.name == "management-vpn"
      ]) && anytrue([
      for r in one(azurerm_firewall_policy_rule_collection_group.build_tenant[0].network_rule_collection).rule :
      r.name == "management-vpn-ssh" && r.destination_ports == tolist(["22"])
    ])
    error_message = "management-vpn reaches every cell's API server (snet-system) on 443; SSH goes to the jump host alone."
  }

  assert {
    condition     = length(azurerm_network_security_rule.management_api_pe_vpn) == 1 && azurerm_network_security_rule.management_api_pe_vpn[0].source_address_prefix == "10.0.1.4"
    error_message = "the API server private endpoints accept labfw's SNATed VPN traffic."
  }

  assert {
    condition     = tolist(azurerm_virtual_network.management.dns_servers) == tolist(["10.0.1.4"])
    error_message = "with labfw.spoke_dns_proxy the spokes resolve through labfw."
  }

  assert {
    condition     = tolist(azurerm_container_group.runners["01"].dns_config[0].nameservers) == tolist(["10.0.1.4"])
    error_message = "with labfw.spoke_dns_proxy the runners resolve through labfw."
  }

  assert {
    condition     = length(azurerm_private_dns_zone_virtual_network_link.hub_zones) == 0
    error_message = "with labfw.spoke_dns_proxy no spoke links to the hub zones."
  }
}

run "labfw_mode_needs_policies" {
  command = plan

  variables {
    network_mode       = "labfw"
    firewall_exposures = {}
  }

  expect_failures = [var.labfw]
}

run "labfw_hybrid_readers" {
  command = plan

  variables {
    network_mode                      = "sandbox"
    labfw_hybrid_reader_principal_ids = ["11111111-1111-1111-1111-111111111111"]
  }

  assert {
    condition     = length(azurerm_role_assignment.labfw_hybrid_policy_reader) == 1 && length(azurerm_role_assignment.labfw_hybrid_service_tags) == 1 && azurerm_role_definition.labfw_service_tags[0].permissions[0].actions == tolist(["Microsoft.Network/locations/serviceTags/read"])
    error_message = "a hybrid labfw reads the policies' resource group and the service tags, in any network mode."
  }
}
