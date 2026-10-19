# labfw's connection log in Log Analytics (var.log_analytics) - what an Azure Firewall's diagnostic setting gives its
# resource-specific tables (AZFWApplicationRule, AZFWNetworkRule): the Azure Monitor Agent on the VM reads labfw's
# JSON lines (logging.file, /var/log/labfw/azfw.jsonl, the AZFW field names) into the custom table
# LabfwFirewallLog_CL of a workspace of its own, through a data collection rule. Only denied connections by default
# (the egress agent's input, design D61; allowed ones would cost ingestion for nothing). Readers query it with Reader
# on the workspace (or the hub subscription); nothing needs to log in to the VM. The agent's own identity needs no
# role: the rule's association authorizes it.
locals {
  log_analytics = var.log_analytics.enabled
  log_columns = {
    TimeGenerated       = "datetime"
    Category            = "string"
    Action              = "string"
    ActionReason        = "string"
    SourceIp            = "string"
    SourcePort          = "int"
    DestinationIp       = "string"
    DestinationPort     = "int"
    Protocol            = "string"
    Fqdn                = "string"
    TargetUrl           = "string"
    Policy              = "string"
    RuleCollectionGroup = "string"
    RuleCollection      = "string"
    Rule                = "string"
  }
  log_stream = "Custom-LabfwFirewallLog_CL"
}

resource "azurerm_log_analytics_workspace" "labfw" {
  count               = local.log_analytics ? 1 : 0
  name                = "log-${var.name_prefix}-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.labfw.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics.retention_in_days
  daily_quota_gb      = var.log_analytics.daily_quota_gb
  # Entra ID only: queries with workspace or resource permissions, no shared keys
  local_authentication_enabled = false
  # Without public network access only through the hub's Azure Monitor Private Link scope
  internet_ingestion_enabled = var.log_analytics.public_network_access
  internet_query_enabled     = var.log_analytics.public_network_access
  tags                       = local.tags
}

resource "azurerm_log_analytics_workspace_table_custom_log" "labfw" {
  count        = local.log_analytics ? 1 : 0
  name         = "LabfwFirewallLog_CL"
  workspace_id = azurerm_log_analytics_workspace.labfw[0].id
  description  = "labfw connection log (AZFW field names), from /var/log/labfw/azfw.jsonl"

  dynamic "column" {
    for_each = local.log_columns
    content {
      name = column.key
      # The table's type names (dateTime) are not the data collection rule's (datetime)
      type = column.value == "datetime" ? "dateTime" : column.value
    }
  }
}

resource "azurerm_monitor_data_collection_endpoint" "labfw" {
  count               = local.log_analytics ? 1 : 0
  name                = "dce-${var.name_prefix}-${var.location}"
  location            = var.location
  resource_group_name = azurerm_resource_group.labfw.name
  kind                = "Linux"
  # The agent reaches it through the hub's Azure Monitor Private Link scope: labfw resolves through the hub's links
  public_network_access_enabled = var.log_analytics.public_network_access
  tags                          = local.tags
}

resource "azurerm_monitor_data_collection_rule" "labfw" {
  count                       = local.log_analytics ? 1 : 0
  name                        = "dcr-${var.name_prefix}-${var.location}"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.labfw.name
  kind                        = "Linux"
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.labfw[0].id
  tags                        = local.tags

  destinations {
    log_analytics {
      name                  = "workspace"
      workspace_resource_id = azurerm_log_analytics_workspace.labfw[0].id
    }
  }

  data_flow {
    streams       = [local.log_stream]
    destinations  = ["workspace"]
    output_stream = local.log_stream
    transform_kql = var.log_analytics.denied_only ? "source | where Action == \"Deny\"" : "source | where isnotempty(Action)"
  }

  data_sources {
    log_file {
      name          = "labfw"
      format        = "json"
      file_patterns = ["/var/log/labfw/azfw.jsonl"]
      streams       = [local.log_stream]
    }
  }

  stream_declaration {
    stream_name = local.log_stream
    dynamic "column" {
      for_each = local.log_columns
      content {
        name = column.key
        type = column.value
      }
    }
  }

  depends_on = [azurerm_log_analytics_workspace_table_custom_log.labfw]
}

resource "azurerm_virtual_machine_extension" "monitor_agent" {
  count                      = local.log_analytics ? 1 : 0
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.labfw.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  # The VM's user-assigned identity signs the agent in
  settings = jsonencode({
    authentication = {
      managedIdentity = {
        identifier-name  = "mi_res_id"
        identifier-value = azurerm_user_assigned_identity.labfw.id
      }
    }
  })
  tags = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "labfw" {
  count                   = local.log_analytics ? 1 : 0
  name                    = "labfw-log"
  target_resource_id      = azurerm_linux_virtual_machine.labfw.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.labfw[0].id
}

resource "azurerm_monitor_data_collection_rule_association" "labfw_endpoint" {
  count                       = local.log_analytics ? 1 : 0
  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_linux_virtual_machine.labfw.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.labfw[0].id
}
