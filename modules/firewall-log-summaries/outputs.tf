output "queries" {
  description = "Summary rule name => its KQL query, as the rule runs it."
  value       = local.queries
}

output "bin_sizes" {
  description = "Summary rule name => its bin in minutes."
  value       = { for name, r in local.rules : name => r.bin_size }
}

output "tables" {
  description = "Summary rule name => its destination table."
  value       = { for name, r in local.rules : name => r.table }
}

output "rule_ids" {
  description = "Summary rule name => its resource ID."
  value       = { for name, r in azapi_resource.rule : name => r.id }
}
