# The hub Firewall's log summaries (OneK8s design section 5.1, decision D84): three Azure Monitor summary rules in the
# Firewall's own Log Analytics workspace aggregate its connection log on a schedule into tables that name the
# environment and zone of every source, the destination and the rule - what the reviews, the denial detection and the
# trend per zone ask the raw log for over and over. The query is free on an Analytics-plan source, the results are a
# few rows per bin; the raw log keeps its own (short) retention, the summaries a long one.
#
# A rule runs over one bin (the bin is its time range: no time filter, no `union *`, no `isfuzzy`, no user-defined
# functions); Azure aggregates a bin after it closes plus a delay of 3.5 minutes to 10 % of the bin, so an hourly
# table shows a denial 1-2 hours later and the daily one the next day. The egress agent keeps reading the raw log.
locals {
  # SourceIp => "<environment>|<zone>": the first network whose prefixes hold the address, else "other"
  attribution_cases = [
    for n in var.networks :
    "    ipv4_is_in_any_range(SourceIp, dynamic([${join(", ", [for p in n.prefixes : "\"${p}\""])}])), \"${n.environment}|${n.zone}\","
  ]
  attribution = join("\n", concat(
    length(var.networks) == 0 ? ["| extend Network = \"other\""] : concat(["| extend Network = case("], local.attribution_cases, ["    \"other\")"]),
    [
      "| extend Environment = tostring(split(Network, \"|\")[0]), Zone = coalesce(tostring(split(Network, \"|\")[1]), \"other\")",
      "| extend Destination = iff(isnotempty(Fqdn), Fqdn, DestinationIp)",
    ],
  ))

  # The destination tables' columns, as the queries return them. The rules add _RuleName, _RuleLastModifiedTime,
  # _BinSize and _BinStartTime themselves; TimeGenerated is the service's (the bin's), never the query's.
  columns = {
    TimeGenerated       = "dateTime"
    Environment         = "string"
    Zone                = "string"
    SourceIp            = "string"
    Action              = "string"
    Category            = "string"
    Protocol            = "string"
    Destination         = "string"
    DestinationPort     = "int"
    Policy              = "string"
    RuleCollectionGroup = "string"
    RuleCollection      = "string"
    Rule                = "string"
    ActionReason        = "string"
    Count               = "long"
    Sources             = "long"
    Destinations        = "long"
    FirstSeen           = "dateTime"
    LastSeen            = "dateTime"
  }

  rules = {
    # Every denied flow per hour, per source address and destination: the denial detection per zone, the evidence of
    # an egress review and of the isolation between zones
    firewall-denied-flows = {
      display_name = "Firewall denied flows"
      description  = "Denied connections per hour: environment and zone of the source, source address, destination (FQDN, else address), port, the rule or default action that denied them; count, first and last seen."
      bin_size     = 60
      table        = "FirewallDeniedFlows_CL"
      retention    = var.hourly_retention_days
      group_by     = ["Environment", "Zone", "SourceIp", "Category", "Protocol", "Destination", "DestinationPort", "Policy", "RuleCollectionGroup", "RuleCollection", "Rule", "ActionReason"]
      measures     = ["Count = count()", "FirstSeen = min(TimeGenerated)", "LastSeen = max(TimeGenerated)"]
      filter       = ["| where Action == \"Deny\""]
    }
    # Rule hygiene: which rule each zone uses, how often, from how many sources to how many destinations
    firewall-rule-hits = {
      display_name = "Firewall rule hits"
      description  = "Logged connections per hour and rule: environment and zone of the source, action, the rule (or default action); count, distinct sources and destinations."
      bin_size     = 60
      table        = "FirewallRuleHits_CL"
      retention    = var.hourly_retention_days
      group_by     = ["Environment", "Zone", "Action", "Category", "Policy", "RuleCollectionGroup", "RuleCollection", "Rule", "ActionReason"]
      measures     = ["Count = count()", "Sources = dcount(SourceIp)", "Destinations = dcount(Destination)"]
      filter       = []
    }
    # The long trend per zone and day: capacity, the Firewall's data processing cost, the weekly comparison
    firewall-zone-traffic = {
      display_name = "Firewall zone traffic"
      description  = "Logged connections per day: environment and zone of the source, action, protocol and destination port; count, distinct sources and destinations."
      bin_size     = 1440
      table        = "FirewallZoneTraffic_CL"
      retention    = var.daily_retention_days
      group_by     = ["Environment", "Zone", "Action", "Category", "Protocol", "DestinationPort"]
      measures     = ["Count = count()", "Sources = dcount(SourceIp)", "Destinations = dcount(Destination)"]
      filter       = []
    }
  }

  queries = {
    for name, r in local.rules : name => join("\n", concat(
      [trimspace(var.source_table)],
      r.filter,
      [local.attribution],
      ["| summarize ${join(", ", r.measures)}", "    by ${join(", ", r.group_by)}"],
    ))
  }
}

# Created ahead of the rules, so that their retention and column types are Terraform's: a rule only appends the
# columns it needs (its own _RuleName, _RuleLastModifiedTime, _BinSize, _BinStartTime) - hence ignore_changes
resource "azurerm_log_analytics_workspace_table_custom_log" "summary" {
  for_each                = local.rules
  name                    = each.value.table
  workspace_id            = var.workspace_id
  display_name            = each.value.display_name
  description             = "Summary rule ${each.key} (${each.value.bin_size} min bins): ${each.value.description}"
  plan                    = "Analytics"
  retention_in_days       = each.value.retention
  total_retention_in_days = each.value.retention

  dynamic "column" {
    for_each = concat(["TimeGenerated"], each.value.group_by, [for m in each.value.measures : trimspace(split("=", m)[0])])
    content {
      name = column.value
      type = local.columns[column.value]
    }
  }

  lifecycle {
    ignore_changes = [column]
  }
}

# Microsoft.OperationalInsights/workspaces/summaryLogs: 2025-07-01 is the newest stable version in azapi's embedded
# schema (2.13; the specs have 2026-03-01, which adds only a user-assigned identity), so azapi validates the body at
# plan
resource "azapi_resource" "rule" {
  for_each  = local.rules
  type      = "Microsoft.OperationalInsights/workspaces/summaryLogs@2025-07-01"
  name      = each.key
  parent_id = var.workspace_id
  body = {
    properties = {
      ruleType    = "User"
      displayName = each.value.display_name
      description = each.value.description
      ruleDefinition = {
        query            = local.queries[each.key]
        binSize          = each.value.bin_size
        destinationTable = each.value.table
      }
    }
  }

  depends_on = [azurerm_log_analytics_workspace_table_custom_log.summary]
}

# The rules' run log (LASummaryLogs: Started | Succeeded | Failed per bin, QueryDurationMs) in the same workspace. A
# failed bin is retried 10 times within 8 hours, then skipped; after 8 failed bins in a row the rule stops - the
# platform's alert is `LASummaryLogs | where Status == "Failed"`.
resource "azurerm_monitor_diagnostic_setting" "run_log" {
  count                      = var.run_log ? 1 : 0
  name                       = "summary-rules-run-log"
  target_resource_id         = var.workspace_id
  log_analytics_workspace_id = var.workspace_id

  enabled_log {
    category = "SummaryLogs"
  }
}
