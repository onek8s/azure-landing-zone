variable "workspace_id" {
  type        = string
  description = "Resource ID of the hub Firewall's Log Analytics workspace: the rules run there, their tables and the run log stay there."
  nullable    = false
}

variable "source_table" {
  type        = string
  default     = "LabfwFirewallLog_CL"
  description = <<DESCRIPTION
The Firewall log as a KQL table expression with the AZFW column names (Category, Action, ActionReason, SourceIp,
DestinationIp, DestinationPort, Protocol, Fqdn, Policy, RuleCollectionGroup, RuleCollection, Rule): labfw's
`LabfwFirewallLog_CL`; an Azure Firewall's resource-specific tables as
`union AZFWApplicationRule, AZFWNetworkRule | extend Category = Type`. (A module input cannot be called `source`.)
Summary rules refuse `union *` and `isfuzzy=true`, and the bin is the time range: no time filter.
DESCRIPTION
  nullable    = false
  validation {
    condition     = !can(regex("(?i)union[^|]*\\*", var.source_table)) && !strcontains(lower(var.source_table), "isfuzzy") && !strcontains(var.source_table, "ago(")
    error_message = "A summary rule's source may not use `union *` or `isfuzzy`, nor filter on time (ago(...)): the bin is the time range."
  }
}

variable "networks" {
  type = list(object({
    environment = string
    zone        = string # an isolation zone, or the environment's `system` / `shared` networks, or a build tenant network
    prefixes    = list(string)
  }))
  default     = []
  nullable    = false
  description = "SourceIp attribution, in order (the first network whose prefixes hold the address wins; everything else is `other`): the same prefixes as the Firewall Policies' IP groups."
  validation {
    condition     = alltrue([for n in var.networks : can(regex("^[A-Za-z0-9_.-]+$", n.environment)) && can(regex("^[A-Za-z0-9_.-]+$", n.zone)) && length(n.prefixes) > 0 && alltrue([for p in n.prefixes : can(cidrhost(p, 0))])])
    error_message = "Every network needs an environment and a zone of letters, digits, `_`, `.` or `-` (no `|`, no quotes) and at least one CIDR prefix."
  }
}

variable "hourly_retention_days" {
  type        = number
  default     = 90
  nullable    = false
  description = "Retention (interactive and total) of the hourly tables FirewallDeniedFlows_CL and FirewallRuleHits_CL."
  validation {
    condition     = var.hourly_retention_days >= 4 && var.hourly_retention_days <= 730
    error_message = "A table's interactive retention is 4 to 730 days."
  }
}

variable "daily_retention_days" {
  type        = number
  default     = 395
  nullable    = false
  description = "Retention (interactive and total) of the daily table FirewallZoneTraffic_CL: 13 months, like metrics."
  validation {
    condition     = var.daily_retention_days >= 4 && var.daily_retention_days <= 730
    error_message = "A table's interactive retention is 4 to 730 days."
  }
}

variable "run_log" {
  type        = bool
  default     = true
  nullable    = false
  description = "The workspace's diagnostic setting that sends its summary rules' run log (category SummaryLogs) to itself, table LASummaryLogs. Off when the workspace already has one with that category."
}
