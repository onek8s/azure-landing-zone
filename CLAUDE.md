# OneK8s landing zone - notes for Claude sessions

The shared working notes for all OneK8s repos are in `onek8s/aks-terraform/CLAUDE.md`. Read that first.

This repo builds the tenant foundation (ALZ, hub, management, deployment identities) and the AKS
policy assignments (`stacks/aks-policy`). It holds **no AKS clusters**: the old
`stacks/aks-stateless-cell` and `stacks/aks-environment` were removed on purpose - clusters and their
shared resources live in aks-terraform. `docs/design-mapping.md` maps the design's requirements to
the code across all repos; keep it current when a decision changes. `docs/traffic-flows/<spoke>/` holds the **generated**
traffic flow pages (design section 5.3): a Mermaid picture per application namespace and per isolation zone, written by
aks-ai-agents' `aks-agent docs traffic` (aks-terraform workflow `Traffic flow docs`) from the rule files in
`stacks/platform-extensions/firewall-applications/`, the cell tfvars, the applications' Flux configuration and the fleet's
allow-lists - never edit them by hand; regenerate them after a change to a rule file.

**Policy `h2c-upstream` (2026-10-18, design D69/D70, audit):** every port of every Service in an application namespace
(the `kubernetes_excluded_namespaces` left out) declares `appProtocol: kubernetes.io/h2c`, so the zone gateway speaks
HTTP/2 to the pod, never HTTP/1.1. Promote to `kubernetes_deny` once Cluster status shows 0 violations on a running
cell with aks-fluxcd-example #37 synced (boot-log's busybox Service is the known finding in cells that run it).
