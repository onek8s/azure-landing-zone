/*
Platform landing zone of the AKS platform build tenant (OneK8s design section 7.1).

Based on the accelerator example `full-single-region/hub-and-spoke-vnet.tfvars` with these build tenant decisions:
- Three subscriptions: sub-mgmt (management), sub-hub (connectivity) and sub-aks-dev (placed in `corp`).
  identity / security subscriptions are not used, their management groups exist so the hierarchy is the same
  as in the corporate landing zone.
- Hub: Azure Firewall (network mode `firewall` only; Standard in the lab – the design is Premium with IDPS:
  set primary_firewall_sku_tier and add intrusion_detection to firewall_policy), Bastion (off in the lab, needed
  only for the optional jump host / test client), the private link DNS zones of Key Vault and ACR (all ~90 in
  the design). The applications' domain is not the hub's: onek8s/aks-terraform publishes them in one zone,
  public or private (dns_zone_private there) – public onek8s.lol in the lab. No Private DNS Resolver in the lab:
  spokes resolve through the Firewall DNS proxy, or in sandbox mode through Azure DNS with every hub zone linked
  to the spoke VNet (the design forwards the corporate DNS to the resolver).
  NO ExpressRoute / VPN gateway – the build tenant is never connected to the corporate network.
- Management: the Log Analytics workspace only (daily cap 1 GB in the lab), no VM monitoring rules.
- No DDoS protection plan (no public endpoints in any spoke, only Front Door).
- ALL policy assignments in enforcement mode `DoNotEnforce` (= audit). Switch `policy_enforcement_mode` to
  `Default` before phase 3 (acceptance testing); see docs/deployment.md.

Address plan: the hub and the shared networks of the build tenant use 10.0.0.0/16, the corporate network that
the client VNet simulates uses 10.200.0.0/16, the AKS environments use one /12 each (dev 10.16.0.0/12) as in
OneK8s design section 8. Replace all of them with the prefixes reserved from the corporate IPAM.

--- Built-in Replacements ---
Replacements are denoted by the dollar-dollar curly braces token (e.g. $${starter_location_01}):
`starter_location_01`, `starter_location_01_short`, `root_parent_management_group_id`,
`subscription_id_identity`, `subscription_id_connectivity`, `subscription_id_management`,
`subscription_id_security`.
*/

starter_locations = ["germanywestcentral"]

custom_replacements = {
  names = {
    # Build tenant switches
    policy_enforcement_mode         = "DoNotEnforce" # Default from phase 3 on
    defender_email_security_contact = "platform-security@example-test.com"

    # Application landing zone subscriptions placed by this stack
    subscription_id_aks_dev = "" # sub-aks-dev ID once it exists (empty: not placed)

    # Resource provisioning global connectivity
    ddos_protection_plan_enabled = false

    # Resource provisioning primary connectivity
    primary_firewall_enabled                                             = false
    primary_firewall_sku_tier                                            = "Standard"
    primary_firewall_management_ip_enabled                               = false
    primary_virtual_network_gateway_express_route_enabled                = false
    primary_virtual_network_gateway_express_route_hobo_public_ip_enabled = false
    primary_virtual_network_gateway_vpn_enabled                          = false
    primary_private_dns_zones_enabled                                    = true
    primary_private_dns_auto_registration_zone_enabled                   = false
    primary_private_dns_resolver_enabled                                 = false
    primary_bastion_enabled                                              = false

    # Resource group names
    management_resource_group_name               = "rg-management-$${starter_location_01}"
    connectivity_hub_primary_resource_group_name = "rg-hub-$${starter_location_01}"
    dns_resource_group_name                      = "rg-hub-dns-$${starter_location_01}"
    ddos_resource_group_name                     = "rg-hub-ddos-$${starter_location_01}"
    asc_export_resource_group_name               = "rg-asc-export-$${starter_location_01}"
    service_health_alerts_resource_group_name    = "rg-service-health-alerts-$${starter_location_01}"

    # Resource names management
    log_analytics_workspace_name            = "law-management-$${starter_location_01}"
    ddos_protection_plan_name               = "ddos-$${starter_location_01}"
    ama_user_assigned_managed_identity_name = "uami-management-ama-$${starter_location_01}"
    dcr_change_tracking_name                = "dcr-change-tracking"
    dcr_defender_sql_name                   = "dcr-defender-sql"
    dcr_vm_insights_name                    = "dcr-vm-insights"

    # Resource names primary connectivity
    primary_virtual_network_name                                 = "vnet-hub-$${starter_location_01}"
    primary_firewall_name                                        = "fw-hub-$${starter_location_01}"
    primary_firewall_policy_name                                 = "fwp-hub-$${starter_location_01}"
    primary_firewall_public_ip_name                              = "pip-fw-hub-$${starter_location_01}"
    primary_firewall_management_public_ip_name                   = "pip-fw-hub-mgmt-$${starter_location_01}"
    primary_route_table_firewall_name                            = "rt-hub-fw-$${starter_location_01}"
    primary_route_table_user_subnets_name                        = "rt-hub-std-$${starter_location_01}"
    primary_virtual_network_gateway_express_route_name           = "vgw-hub-er-$${starter_location_01}"
    primary_virtual_network_gateway_express_route_public_ip_name = "pip-vgw-hub-er-$${starter_location_01}"
    primary_virtual_network_gateway_vpn_name                     = "vgw-hub-vpn-$${starter_location_01}"
    primary_virtual_network_gateway_vpn_public_ip_name_1         = "pip-vgw-hub-vpn-$${starter_location_01}-001"
    primary_virtual_network_gateway_vpn_public_ip_name_2         = "pip-vgw-hub-vpn-$${starter_location_01}-002"
    primary_private_dns_resolver_name                            = "pdr-hub-dns-$${starter_location_01}"
    primary_bastion_host_name                                    = "bas-hub-$${starter_location_01}"
    primary_bastion_host_public_ip_name                          = "pip-bastion-hub-$${starter_location_01}"

    # Private DNS Zones primary
    primary_auto_registration_zone_name = "$${starter_location_01}.azure.local"

    # IP Ranges Primary
    # Regional Address Space of the shared networks: 10.0.0.0/16
    #   10.0.0.0/22  hub (this stack)
    #   10.0.8.0/22  management VNet in sub-mgmt (stacks/platform-extensions)
    #   10.200.0.0/22 client VNet simulating the corporate network (stacks/platform-extensions)
    primary_hub_address_space                          = "10.0.0.0/16"
    primary_hub_virtual_network_address_space          = "10.0.0.0/22"
    primary_firewall_subnet_address_prefix             = "10.0.0.0/26"
    primary_firewall_management_subnet_address_prefix  = "10.0.0.192/26"
    primary_bastion_subnet_address_prefix              = "10.0.0.64/26"
    primary_gateway_subnet_address_prefix              = "10.0.0.128/27"
    primary_private_dns_resolver_subnet_address_prefix = "10.0.0.160/28"
  }

  resource_group_identifiers = {
    management_resource_group_id           = "/subscriptions/$${subscription_id_management}/resourcegroups/$${management_resource_group_name}"
    ddos_protection_plan_resource_group_id = "/subscriptions/$${subscription_id_connectivity}/resourcegroups/$${ddos_resource_group_name}"
    primary_connectivity_resource_group_id = "/subscriptions/$${subscription_id_connectivity}/resourceGroups/$${connectivity_hub_primary_resource_group_name}"
    dns_resource_group_id                  = "/subscriptions/$${subscription_id_connectivity}/resourceGroups/$${dns_resource_group_name}"
  }

  resource_identifiers = {
    ama_change_tracking_data_collection_rule_id = "$${management_resource_group_id}/providers/Microsoft.Insights/dataCollectionRules/$${dcr_change_tracking_name}"
    ama_mdfc_sql_data_collection_rule_id        = "$${management_resource_group_id}/providers/Microsoft.Insights/dataCollectionRules/$${dcr_defender_sql_name}"
    ama_vm_insights_data_collection_rule_id     = "$${management_resource_group_id}/providers/Microsoft.Insights/dataCollectionRules/$${dcr_vm_insights_name}"
    ama_user_assigned_managed_identity_id       = "$${management_resource_group_id}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$${ama_user_assigned_managed_identity_name}"
    log_analytics_workspace_id                  = "$${management_resource_group_id}/providers/Microsoft.OperationalInsights/workspaces/$${log_analytics_workspace_name}"
    ddos_protection_plan_id                     = "$${ddos_protection_plan_resource_group_id}/providers/Microsoft.Network/ddosProtectionPlans/$${ddos_protection_plan_name}"
  }
}

tags = {
  deployed_by = "terraform"
  source      = "Azure Landing Zones Accelerator"
  platform    = "aks"
  tenant      = "build"
}

/*
--- Management Resources ---
*/
# Lab: no monitoring for now - observability is set up later. No Log Analytics workspace, no Azure Monitor Agent
# identity, no data collection rules; the ALZ assignments that need them are removed in lib/archetype_definitions.
# The settings below are what `true` deploys.
management_resources_enabled = false

management_resource_settings = {
  location                               = "$${starter_location_01}"
  log_analytics_workspace_name           = "$${log_analytics_workspace_name}"
  log_analytics_workspace_daily_quota_gb = 1
  resource_group_name                    = "$${management_resource_group_name}"
  user_assigned_managed_identities = {
    ama = {
      name    = "$${ama_user_assigned_managed_identity_name}"
      enabled = false
    }
  }
  data_collection_rules = {
    change_tracking = {
      name    = "$${dcr_change_tracking_name}"
      enabled = false
    }
    defender_sql = {
      name    = "$${dcr_defender_sql_name}"
      enabled = false
    }
    vm_insights = {
      name    = "$${dcr_vm_insights_name}"
      enabled = false
    }
  }
}

/*
--- Management Groups and Policy ---
The corporate landing zone initiatives (ALZ library, see lib/alz_library_metadata.json) assigned at the same
scopes as in the corporate tenant. The AKS platform's own definitions are assigned per environment subscription
by stacks/aks-policy (OneK8s design section 2.7).
*/
management_groups_enabled = true

management_group_settings = {
  # No retry on not-found when reading policy role assignments: the module default retries ResourceNotFound
  # (eventual consistency after create, which AZAPI_RETRY_GET_AFTER_PUT_MAX_TIME covers in the apply job), so a
  # role assignment whose scope was deleted (e.g. a removed private DNS zone) hangs the plan instead of leaving
  # the state.
  retries = {
    policy_role_assignments = {
      error_message_regex = ["AuthorizationFailed"]
    }
  }
  # Reading a role assignment takes seconds; fail fast instead of the 60-minute default
  timeouts = {
    policy_role_assignment = {
      read = "5m"
    }
  }
  architecture_name  = "alz_custom"
  location           = "$${starter_location_01}"
  parent_resource_id = "$${root_parent_management_group_id}"
  policy_default_values = {
    ama_change_tracking_data_collection_rule_id = "$${ama_change_tracking_data_collection_rule_id}"
    ama_mdfc_sql_data_collection_rule_id        = "$${ama_mdfc_sql_data_collection_rule_id}"
    ama_vm_insights_data_collection_rule_id     = "$${ama_vm_insights_data_collection_rule_id}"
    ama_user_assigned_managed_identity_id       = "$${ama_user_assigned_managed_identity_id}"
    ama_user_assigned_managed_identity_name     = "$${ama_user_assigned_managed_identity_name}"
    log_analytics_workspace_id                  = "$${log_analytics_workspace_id}"
    ddos_protection_plan_id                     = "$${ddos_protection_plan_id}"
    private_dns_zone_subscription_id            = "$${subscription_id_connectivity}"
    private_dns_zone_region                     = "$${starter_location_01}"
    private_dns_zone_resource_group_name        = "$${dns_resource_group_name}"
    resource_group_name_service_health_alerts   = "$${service_health_alerts_resource_group_name}"
    resource_group_name_mdfc                    = "$${asc_export_resource_group_name}"
    resource_group_location                     = "$${starter_location_01}"
    email_security_contact                      = "$${defender_email_security_contact}"
    # No allowed_locations: the ALZ library (platform/alz 2026.x) has no such default and alz provider 0.22 rejects it
  }
  subscription_placement = {
    identity = {
      subscription_id       = "$${subscription_id_identity}"
      management_group_name = "identity"
    }
    connectivity = {
      subscription_id       = "$${subscription_id_connectivity}"
      management_group_name = "connectivity"
    }
    management = {
      subscription_id       = "$${subscription_id_management}"
      management_group_name = "management"
    }
    security = {
      subscription_id       = "$${subscription_id_security}"
      management_group_name = "security"
    }
    # AKS platform environment subscriptions (OneK8s design section 3.2). Corp: connected to the hub, no public
    # endpoints – the only public entry point (Front Door) is a global service outside the spokes.
    aks_dev = {
      subscription_id       = "$${subscription_id_aks_dev}"
      management_group_name = "corp"
    }
  }

  # BEGIN GENERATED policy_assignments_to_modify (scripts/update-policy-enforcement.sh)
  policy_assignments_to_modify = {
    alz = {
      policy_assignments = {
        Deny-UnmanagedDisk = { enforcement_mode = "Default" }
      }
    }
    platform = {
      policy_assignments = {
        Enforce-Encrypt-CMK0    = { enforcement_mode = "Default" }
        Enforce-GR-Compute0     = { enforcement_mode = "Default" }
        Enforce-GR-ContReg0     = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-KeyVault     = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-KeyVaultSup0 = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-Kubernetes0  = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-Network0 = {
          enforcement_mode = "Default"
          parameters = {
            vnetModifyDdos = "Disabled"
          }
        }
        Enforce-GR-Storage0 = {
          enforcement_mode = "Default"
          parameters = {
            storageThreatProtection = "Disabled"
          }
        }
        Enforce-Subnet-Private = { enforcement_mode = "Default" }
      }
    }
    landingzones = {
      policy_assignments = {
        Deny-IP-forwarding      = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-MgmtPorts-Internet = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-Priv-Esc-AKS       = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-Privileged-AKS     = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-Storage-http       = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-Subnet-Without-Nsg = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-AKS-HTTPS       = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-Encrypt-CMK0    = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-Compute0     = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-ContReg0     = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-KeyVault     = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-KeyVaultSup0 = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-Kubernetes0  = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-GR-Network0 = {
          enforcement_mode = "$${policy_enforcement_mode}"
          parameters = {
            vnetModifyDdos = "Disabled"
          }
        }
        Enforce-GR-Storage0 = {
          enforcement_mode = "$${policy_enforcement_mode}"
          parameters = {
            storageThreatProtection = "Disabled"
          }
        }
        Enforce-Subnet-Private = { enforcement_mode = "$${policy_enforcement_mode}" }
        Enforce-TLS-SSL-Q225   = { enforcement_mode = "$${policy_enforcement_mode}" }
      }
    }
    corp = {
      policy_assignments = {
        Audit-PeDnsZones      = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-Public-Endpoints = { enforcement_mode = "$${policy_enforcement_mode}" }
        Deny-Public-IP-On-NIC = { enforcement_mode = "$${policy_enforcement_mode}" }
      }
    }
  }
  # END GENERATED policy_assignments_to_modify
}

/*
--- Connectivity - Hub and Spoke Virtual Network ---
*/
connectivity_type = "hub_and_spoke_vnet"

connectivity_resource_groups = {
  ddos = {
    name     = "$${ddos_resource_group_name}"
    location = "$${starter_location_01}"
    settings = {
      enabled = "$${ddos_protection_plan_enabled}"
    }
  }
  vnet_primary = {
    name     = "$${connectivity_hub_primary_resource_group_name}"
    location = "$${starter_location_01}"
    settings = {
      enabled = true
    }
  }
  dns = {
    name     = "$${dns_resource_group_name}"
    location = "$${starter_location_01}"
    settings = {
      enabled = "$${primary_private_dns_zones_enabled}"
    }
  }
}

hub_and_spoke_networks_settings = {
  enabled_resources = {
    ddos_protection_plan = "$${ddos_protection_plan_enabled}"
  }
  ddos_protection_plan = {
    name                = "$${ddos_protection_plan_name}"
    resource_group_name = "$${ddos_resource_group_name}"
    location            = "$${starter_location_01}"
  }
}

hub_virtual_networks = {
  primary = {
    location          = "$${starter_location_01}"
    default_parent_id = "$${primary_connectivity_resource_group_id}"
    enabled_resources = {
      firewall                              = "$${primary_firewall_enabled}"
      bastion                               = "$${primary_bastion_enabled}"
      virtual_network_gateway_express_route = "$${primary_virtual_network_gateway_express_route_enabled}"
      virtual_network_gateway_vpn           = "$${primary_virtual_network_gateway_vpn_enabled}"
      private_dns_zones                     = "$${primary_private_dns_zones_enabled}"
      private_dns_resolver                  = "$${primary_private_dns_resolver_enabled}"
    }
    hub_virtual_network = {
      name                          = "$${primary_virtual_network_name}"
      address_space                 = ["$${primary_hub_virtual_network_address_space}"]
      routing_address_space         = ["$${primary_hub_address_space}"]
      route_table_name_firewall     = "$${primary_route_table_firewall_name}"
      route_table_name_user_subnets = "$${primary_route_table_user_subnets_name}"
      subnets                       = {}
    }
    firewall = {
      subnet_address_prefix            = "$${primary_firewall_subnet_address_prefix}"
      management_subnet_address_prefix = "$${primary_firewall_management_subnet_address_prefix}"
      name                             = "$${primary_firewall_name}"
      sku_tier                         = "$${primary_firewall_sku_tier}"
      zones                            = ["1", "2", "3"]
      default_ip_configuration = {
        public_ip_config = {
          name  = "$${primary_firewall_public_ip_name}"
          zones = ["1", "2", "3"]
        }
      }
      management_ip_enabled = "$${primary_firewall_management_ip_enabled}"
      management_ip_configuration = {
        public_ip_config = {
          name = "$${primary_firewall_management_public_ip_name}"
        }
      }
    }
    firewall_policy = {
      name = "$${primary_firewall_policy_name}"
      sku  = "$${primary_firewall_sku_tier}"
      # Spokes use the Firewall as DNS server: FQDN-based network rules and the hub private DNS zones
      # (privatelink.*) work in every spoke.
      dns = {
        proxy_enabled = true
      }
      # Premium only (the design): intrusion_detection = { mode = "Alert" }, Deny from phase 3 on
      threat_intelligence_mode = "Alert"
    }
    virtual_network_gateways = {
      subnet_address_prefix = "$${primary_gateway_subnet_address_prefix}"
      express_route = {
        name                                  = "$${primary_virtual_network_gateway_express_route_name}"
        hosted_on_behalf_of_public_ip_enabled = "$${primary_virtual_network_gateway_express_route_hobo_public_ip_enabled}"
        ip_configurations = {
          default = {
            public_ip = {
              name = "$${primary_virtual_network_gateway_express_route_public_ip_name}"
            }
          }
        }
      }
      vpn = {
        name = "$${primary_virtual_network_gateway_vpn_name}"
        ip_configurations = {
          active_active_1 = {
            public_ip = {
              name = "$${primary_virtual_network_gateway_vpn_public_ip_name_1}"
            }
          }
          active_active_2 = {
            public_ip = {
              name = "$${primary_virtual_network_gateway_vpn_public_ip_name_2}"
            }
          }
        }
      }
    }
    private_dns_zones = {
      parent_id = "$${dns_resource_group_id}"
      # Lab: only the private link zones the platform uses instead of all ~90 Azure services - the AKS environments'
      # vaults, registry, Foundry (AI agents) and Terraform state, and Azure Monitor's Private Link scope
      # (stacks/platform-extensions main.monitor.private.tf: Log Analytics and the data collection endpoints). Same
      # keys as the module defaults, so adding more zones back is additive.
      private_link_private_dns_zones = {
        azure_key_vault = {
          zone_name = "privatelink.vaultcore.azure.net"
        }
        azure_acr_registry = {
          zone_name = "privatelink.azurecr.io"
        }
        azure_ai_cog_svcs = {
          zone_name = "privatelink.cognitiveservices.azure.com"
        }
        azure_ai_oai = {
          zone_name = "privatelink.openai.azure.com"
        }
        azure_ai_services = {
          zone_name = "privatelink.services.ai.azure.com"
        }
        azure_storage_blob = {
          zone_name = "privatelink.blob.core.windows.net"
        }
        azure_monitor = {
          zone_name = "privatelink.monitor.azure.com"
        }
        azure_log_analytics = {
          zone_name = "privatelink.oms.opinsights.azure.com"
        }
        azure_log_analytics_data = {
          zone_name = "privatelink.ods.opinsights.azure.com"
        }
        azure_monitor_agent = {
          zone_name = "privatelink.agentsvc.azure-automation.net"
        }
      }
      private_link_private_dns_zones_regex_filter = {
        enabled = false
      }
      auto_registration_zone_enabled = "$${primary_private_dns_auto_registration_zone_enabled}"
      auto_registration_zone_name    = "$${primary_auto_registration_zone_name}"
    }
    private_dns_resolver = {
      subnet_address_prefix = "$${primary_private_dns_resolver_subnet_address_prefix}"
      name                  = "$${primary_private_dns_resolver_name}"
    }
    bastion = {
      subnet_address_prefix = "$${primary_bastion_subnet_address_prefix}"
      name                  = "$${primary_bastion_host_name}"
      sku                   = "Standard"
      tunneling_enabled     = true # `az network bastion ssh/tunnel` to the jump host / test client
      zones                 = ["1", "2", "3"]
      bastion_public_ip = {
        name = "$${primary_bastion_host_public_ip_name}"
      }
    }
  }
}

enable_telemetry = true
telemetry_additional_content = {
  deployed_by    = "alz-terraform-accelerator"
  correlation_id = "00000000-0000-0000-0000-000000000000"
}
