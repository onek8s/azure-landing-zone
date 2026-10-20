output "management_virtual_network_id" {
  description = "Management VNet."
  value       = azurerm_virtual_network.management.id
}

output "management_aks_api_pe_subnet_id" {
  description = "Subnet for the private endpoints to the API servers (used by the cell stack)."
  value       = azurerm_subnet.management_aks_api_pe.id
}

output "client_virtual_network_id" {
  description = "Client VNet simulating the corporate network."
  value       = azurerm_virtual_network.client.id
}

output "aks_environment_identities" {
  description = "Client IDs of the AKS environment deployment identities: set them as AZURE_CLIENT_ID of the GitHub environments aks-<env>-plan / aks-<env>-apply."
  value       = { for k, v in azurerm_user_assigned_identity.aks : "aks-${k}" => v.client_id }
}

output "aks_api_access_resource_groups" {
  description = "Resource group per environment for the API server private endpoints and DNS zones."
  value       = { for k, v in azurerm_resource_group.aks_api_access : k => v.name }
}

output "runner_registry" {
  description = "Private registry that builds the runner image. Null without runners."
  value       = one(azurerm_container_registry.runners[*].login_server)
}

output "labfw" {
  description = "labfw in the hub (network mode labfw): private IP (next hop), public IP, VPN endpoint and client pool, resource group. Null in the other modes."
  value = local.labfw ? {
    private_ip          = module.labfw[0].private_ip
    public_ip           = module.labfw[0].public_ip
    vpn_endpoint        = module.labfw[0].vpn_endpoint
    vpn_pool            = module.labfw[0].vpn_pool
    resource_group_name = module.labfw[0].resource_group_name
    log_analytics       = module.labfw[0].log_analytics_workspace
    # Summary rule => its table (design D84); null without them
    log_summaries = local.labfw_log_summaries ? module.labfw_log_summaries[0].tables : null
  } : null
}

output "network_mode" {
  description = "firewall, sandbox or labfw."
  value       = var.network_mode
}
