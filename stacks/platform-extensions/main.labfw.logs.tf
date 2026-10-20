# labfw's log summaries (OneK8s design section 5.1, decision D84; modules/firewall-log-summaries): three summary rules
# in labfw's workspace (log-labfw-<location>) aggregate LabfwFirewallLog_CL into FirewallDeniedFlows_CL and
# FirewallRuleHits_CL (hourly) and FirewallZoneTraffic_CL (daily), each source attributed to its environment and zone
# from the prefixes the Firewall Policies' IP groups hold - a new zone or cell in firewall_exposures is attributed from
# its first flow. The egress agent keeps reading the raw table.
locals {
  labfw_log_summaries = local.labfw && var.labfw.log_analytics.enabled && var.labfw.log_analytics.summaries.enabled

  # Every environment's zones (by name), then its system and shared networks; then the build tenant's networks, the
  # hub last (it holds the VPN pool's range)
  labfw_log_networks = concat(
    flatten([
      for key in sort(keys(local.firewall_spokes)) : concat(
        [for zone in sort(keys(local.firewall_spokes[key].zones)) : { environment = local.firewall_spokes[key].env, zone = zone, prefixes = local.firewall_spokes[key].zones[zone].prefixes }],
        [{ environment = local.firewall_spokes[key].env, zone = "system", prefixes = local.firewall_spokes[key].system_prefixes }],
        length(local.firewall_spokes[key].shared_prefixes) > 0 ? [{ environment = local.firewall_spokes[key].env, zone = "shared", prefixes = local.firewall_spokes[key].shared_prefixes }] : [],
      )
    ]),
    [
      { environment = "build-tenant", zone = "management", prefixes = [var.management_address_space] },
      { environment = "build-tenant", zone = "client", prefixes = [var.client_address_space] },
    ],
    local.labfw_vpn ? [{ environment = "build-tenant", zone = "vpn", prefixes = local.labfw_vpn_pool }] : [],
    [{ environment = "build-tenant", zone = "hub", prefixes = local.hub_vnet.address_space }],
  )
}

module "labfw_log_summaries" {
  source = "../../modules/firewall-log-summaries"
  count  = local.labfw_log_summaries ? 1 : 0
  providers = {
    azurerm = azurerm.connectivity
    azapi   = azapi
  }

  workspace_id          = module.labfw[0].log_analytics_workspace.id
  source_table          = module.labfw[0].log_analytics_workspace.table
  networks              = local.labfw_log_networks
  hourly_retention_days = var.labfw.log_analytics.summaries.hourly_retention_days
  daily_retention_days  = var.labfw.log_analytics.summaries.daily_retention_days
}
