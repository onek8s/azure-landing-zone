# firewall-log-summaries

The hub Firewall's log summaries (OneK8s design section 5.1, decision D84): three Azure Monitor
[summary rules](https://learn.microsoft.com/azure/azure-monitor/logs/summary-rules) in the Firewall's own Log
Analytics workspace aggregate its connection log on a schedule into tables that name the environment and isolation
zone of every source, the destination and the rule.

**Why:** the reviews, the denial detection per zone and the trend per zone ask the raw log the same questions over and
over (which zone, which destination, which rule, how often). The summaries answer them without a scan of the raw log,
cost nothing to compute on an Analytics-plan source and only a few rows per bin to keep, and outlive the raw log's
short retention. The egress agent (onek8s/aks-ai-agents) keeps reading the raw log: it needs every flow within minutes.

| Rule | Bin | Table | Grouped by | Measures |
|---|---|---|---|---|
| `firewall-denied-flows` | 60 min | `FirewallDeniedFlows_CL` | Environment, Zone, SourceIp, Category, Protocol, Destination, DestinationPort, Policy, RuleCollectionGroup, RuleCollection, Rule, ActionReason (denied flows only) | Count, FirstSeen, LastSeen |
| `firewall-rule-hits` | 60 min | `FirewallRuleHits_CL` | Environment, Zone, Action, Category, Policy, RuleCollectionGroup, RuleCollection, Rule, ActionReason | Count, Sources, Destinations |
| `firewall-zone-traffic` | 1440 min | `FirewallZoneTraffic_CL` | Environment, Zone, Action, Category, Protocol, DestinationPort | Count, Sources, Destinations |

`Destination` is the FQDN, else the destination address. **Attribution:** `networks` is an ordered list of
`{ environment, zone, prefixes }` - the same prefixes as the Firewall Policies' IP groups; the queries map `SourceIp`
to the first network that holds it (`ipv4_is_in_any_range` in a `case`), anything else to `other`. The summaries keep
the source address but never name the pod.

**How:**

- `source_table` is a KQL table expression with the AZFW column names: labfw's `LabfwFirewallLog_CL`; for an Azure
  Firewall's resource-specific tables `union AZFWApplicationRule, AZFWNetworkRule | extend Category = Type`. No time
  filter (the bin is the range), no `union *`, no `isfuzzy` (both refused by summary rules; the input validates it).
- The destination tables are created ahead with `azurerm_log_analytics_workspace_table_custom_log`, so retention
  (`hourly_retention_days`, default 90; `daily_retention_days`, default 395) and column types are Terraform's; a rule
  appends `_RuleName`, `_RuleLastModifiedTime`, `_BinSize` and `_BinStartTime` itself (`ignore_changes = [column]`).
  `TimeGenerated` is the bin's, set by the service.
- The rules are `azapi_resource`s of `Microsoft.OperationalInsights/workspaces/summaryLogs@2025-07-01`.
- `run_log` (default on): the workspace's diagnostic setting sends the category `SummaryLogs` to the workspace itself,
  table `LASummaryLogs` (Started, Succeeded, Failed per bin). Azure retries a failed bin 10 times within 8 hours, then
  skips it; after 8 failed bins in a row the rule stops (`isActive: false`).

**Latency:** a bin is aggregated after it closes plus a delay of about 3.5 minutes to 10 % of the bin: the hourly
tables show a flow 1-2 hours later, the daily table the next day.

**How to check** (from a network that reaches the workspace): the workspace's *Summary rules* blade in the portal, and

```kusto
FirewallDeniedFlows_CL | where TimeGenerated > ago(3h) | summarize sum(Count) by Zone, Destination
FirewallRuleHits_CL | summarize sum(Count) by Zone, Action, Rule, ActionReason
LASummaryLogs | summarize count() by RuleName, Status
LASummaryLogs | where Status == "Failed"
```
