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

**Policy `h2c-upstream` (2026-10-18, design D69/D70; deny since 2026-10-19, D82):** every port of every Service in an application namespace
(the `kubernetes_excluded_namespaces` left out) declares `appProtocol: kubernetes.io/h2c`, so the zone gateway speaks
HTTP/2 to the pod, never HTTP/1.1. Stateless clusters only: boot-log's busybox Service (HTTP/1.1) runs in the stateful one.
The one exception is named, not left to the namespace exclusions (2026-10-19, design D78): `exemptServices =
["flux-system/webhook-receiver"]` - notification-controller's Service behind the platform gateway's `/hook/` route, which
GitHub's webhook deliveries reach over HTTP/1.1 (`<namespace>/<name>`; the definition's default is `[]`) - and since
2026-10-19 `default/kubernetes`, the API server's own Service.

**Policy `gateway-tls` (2026-10-18, design D70/D71; deny since 2026-10-19, D82):** in every `*-gateway` namespace the ConfigMap `traefik-dynamic`
(aks-terraform `gateways/traefik`, Traefik's file-provider dynamic configuration) must state `tls.options.default` with
`alpnProtocols` exactly `[h2]` and `minVersion: VersionTLS13` - HTTP/2 and TLS 1.3 only at the edge, read back so it cannot
drift. `yaml.unmarshal` works in Gatekeeper's Rego (gator v3.21.1).

**ALZ assignments (2026-10-19, the user):** only those for what the AKS platform runs on stay assigned; Defender for
Cloud / Endpoint is not used (a third-party security tool, design D81) - its assignments are removed, Defender for
Storage is `Disabled` inside `Enforce-GR-Storage0`, and Defender for Cloud's own `SecurityCenterBuiltIn` assignment
(created outside Terraform per subscription) was deleted with aks-terraform's Lab admin; delete it again if it
reappears. Non-AKS build tenant resources (bootstrap state, management and hub subnets, labfw) are exempt from the
platform guardrails in `stacks/platform-extensions/main.policy.exemptions.tf`. Key Vault purge protection is assigned
in prd only. The user's rule: **every policy goes to Deny (enforcement `Default`) once it shows 0 non-compliant
resources** (D82): ALZ assignments in `accelerator/config/policy-deny.yaml` (then `scripts/update-policy-enforcement.sh`,
`scripts/sync-platform.sh`), AKS rules in `kubernetes_deny`. An assignment that evaluates nothing waits until it has.
