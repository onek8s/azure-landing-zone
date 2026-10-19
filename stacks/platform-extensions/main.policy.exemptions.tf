# Policy exemptions for the build tenant's own resources that are not the AKS platform's (approved by the user,
# 2026-10-19): the ALZ guardrails assigned at the platform management group apply to sub-mgmt and sub-hub, where
# the accelerator's state, the management and hub networks and labfw run. The AKS platform's resources get no
# exemption - they comply, or the finding is fixed.
locals {
  alz_platform_assignment_id = "/providers/Microsoft.Management/managementGroups/platform/providers/Microsoft.Authorization/policyAssignments"

  policy_exemptions = merge(
    {
      # The accelerator bootstrap's Terraform state account (storage network rules, customer-managed keys)
      bootstrap-state-storage = {
        resource_group_id = "/subscriptions/${var.subscription_ids["management"]}/resourceGroups/${var.bootstrap_state_resource_group_name}"
        assignment        = "Enforce-GR-Storage0"
        references        = null
        description       = "The ALZ accelerator bootstrap's Terraform state account, outside the AKS platform."
      }
      bootstrap-state-cmk = {
        resource_group_id = "/subscriptions/${var.subscription_ids["management"]}/resourceGroups/${var.bootstrap_state_resource_group_name}"
        assignment        = "Enforce-Encrypt-CMK0"
        references        = null
        description       = "The ALZ accelerator bootstrap's Terraform state account, outside the AKS platform."
      }
      # Private endpoint subnets of the management VNet: no route table of their own
      management-network-udr = {
        resource_group_id = azurerm_resource_group.management_network.id
        assignment        = "Enforce-GR-Network0"
        references        = ["Deny-Subnet-Without-Udr"]
        description       = "The management VNet's private endpoint subnets, outside the AKS platform."
      }
      # The hub's own subnets route to the internet themselves
      hub-network-udr = {
        resource_group_id = "/subscriptions/${var.subscription_ids["connectivity"]}/resourceGroups/${local.hub_vnet.resource_group_name}"
        assignment        = "Enforce-GR-Network0"
        references        = ["Deny-Subnet-Without-Udr"]
        description       = "The hub VNet's subnets, outside the AKS platform."
      }
    },
    # labfw, the lab's stand-in for the hub Azure Firewall: a VM with a public IP and IP forwarding on its NIC and
    # an OS disk with platform-managed keys, without encryption at host
    local.labfw ? {
      for assignment in ["Enforce-GR-Network0", "Enforce-Encrypt-CMK0", "Enforce-GR-Compute0"] :
      "labfw-${lower(assignment)}" => {
        resource_group_id = module.labfw[0].resource_group_id
        assignment        = assignment
        references        = null
        description       = "labfw, the lab's stand-in for the hub Azure Firewall, outside the AKS platform."
      }
    } : {},
  )
}

resource "azurerm_resource_group_policy_exemption" "build_tenant" {
  provider                        = azurerm.management
  for_each                        = local.policy_exemptions
  name                            = "onek8s-${each.key}"
  display_name                    = "OneK8s build tenant: ${each.key}"
  description                     = each.value.description
  resource_group_id               = each.value.resource_group_id
  policy_assignment_id            = "${local.alz_platform_assignment_id}/${each.value.assignment}"
  policy_definition_reference_ids = each.value.references
  exemption_category              = "Waiver"
}
