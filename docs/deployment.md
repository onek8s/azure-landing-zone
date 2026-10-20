# Deploying the build tenant and the dev environment

This is phase 1 (Foundation) of the [implementation project](https://github.com/onek8s/onek8s.github.io/blob/main/archive/7.1-implementation-project-and-acceptance-testing.md):
build tenant, management and hub, `sub-aks-dev`, pipelines with OIDC, Azure Policy in audit mode and the client
VNet. **Exit criterion: a stateless cell can be created and deleted by the pipeline** (step 8). The clusters
themselves - the cells, their networks, Key Vaults and Traffic Manager - are
[onek8s/aks-terraform](https://github.com/onek8s/aks-terraform)'s, deployed into `sub-aks-dev` with this
repository's dev apply identity.

```text
 step 2  Deploy-Accelerator (alz_local)  ──► state storage + plan/apply identities, federated with GitHub
 step 6  workflow "Platform"             ──► platform/ (ALZ: management groups, policy, management, hub)
                                          └► stacks/platform-extensions (management VNet + runners, client VNet,
                                             Firewall rules, AKS deployment identities)
 step 7  workflow "AKS policy"           ──► stacks/aks-policy (environments/dev/policy.tfvars, GitHub-hosted)
         onek8s/aks-terraform "Deploy"  ──► shared/ (cells' networks, vaults, Traffic Manager), then each cell
 step 8  onek8s/aks-terraform "Deploy"  ──► destroy / apply one cell
```

## Network mode: firewall, sandbox or labfw

One flag in [`network-mode.tfvars`](../network-mode.tfvars) decides how the networks are connected. Switch it
with the script – it also sets `primary_firewall_enabled` in the accelerator configuration and regenerates
`platform/`; CI fails if the two disagree:

```bash
scripts/set-network-mode.sh sandbox   # or: firewall, labfw
git add -A && git commit -m "Network mode sandbox" && git push
```

| | `firewall` (the design) | `sandbox` (lab / prototype) | `labfw` (lab with a firewall) |
|---|---|---|---|
| Azure Firewall | in the hub (Standard in the lab, Premium in the design), DNS proxy, rule collection groups per zone | not deployed | not deployed: [labfw](https://github.com/onek8s/azure-lab-fw) VM `labfw-fw` in `snet-labfw` (10.0.1.4) of the hub, resource group `rg-hub-labfw-<region>`, enforcing the D53 child policy `afwp-hub-<labfw.policy_exposure>-<region>` with its parent |
| Routing | every subnet: `0.0.0.0/0` and the other zones' address spaces → Firewall; spokes peered to the hub only | no route tables; the cells (aks-terraform) are networks of their own, not peered to the hub | as `firewall`, with labfw as next hop: the management and client VNets and the cells (aks-terraform `shared/` `hub`) peered to the hub only, `0.0.0.0/0` → labfw |
| Zone isolation | NSG + Firewall + Cilium | NSG + Cilium – the same deny-by-default NSGs are the only network boundary | NSG + labfw (the D53 policies) + Cilium |
| Internet egress | Firewall FQDN allow-lists, AKS outbound type `userDefinedRouting` | NAT gateways (cells: zonal in the cell's AZ, AKS outbound type `userAssignedNATGateway`; management VNet only with runners or the jump host, client VNet only with the test client); nodes have open egress, pods are still limited by Cilium FQDN policies | the policies' allow-lists (`rcg-build-tenant` and `rcg-platform` in the parent, the exposure's child), AKS outbound type `userDefinedRouting` |
| DNS | Firewall DNS proxy | Azure DNS; each stack links its VNets to every hub private DNS zone | labfw's DNS proxy with `labfw.spoke_dns_proxy = true` (the lab's), else as `sandbox`; aks-terraform links the internal zones' private DNS to the hub so labfw resolves them |
| Remote access | – | – | optional WireGuard VPN on labfw for agent and management machines outside Azure (`labfw.vpn`) |
| Cost | the Firewall is the largest fixed cost of the build tenant | NAT gateways and public IPs only | one B-series VM, an HDD OS disk and a public IP (roughly $10–20/month) |

The lab runs `labfw` (2026-10-15): the routing of `firewall` mode without the Firewall's cost. Use `sandbox` for a
first run in your own lab; acceptance testing (phase 3) runs in `firewall` mode, because the
Firewall is part of what is accepted. Switching later is an ordinary change: with `firewall` the next runs create
the Firewall, route tables and rules and remove the direct peerings and NAT gateways (run Platform, then AKS
dev). The NAT gateway public IPs are flagged by the ALZ `corp` policies – fine while they are in audit mode.

### labfw mode

labfw is the build tenant's cheap stand-in for Azure Firewall: a VM that reads the Firewall Policies of
`stacks/platform-extensions/main.firewall.policies.tf` from ARM and enforces their network, application and DNAT
rules. `modules/labfw` deploys it like azure-lab-fw's own Bicep does, with that repository's cloud-init and
install script vendored into `modules/labfw/vendor` (`scripts/vendor-labfw.sh <tag>` refreshes them; keep the tag
equal to `labfw.release_version`). Configuration or version changes reach the running VM through a managed Run
Command, without replacing it. Its identity is Reader on `sub-hub` (policies, IP groups, service tags).

Switching an existing lab to `labfw`:

1. If azure-lab-fw's own lab is deployed into the hub (its `deploy-lab` with `mode=existing-hub`): **wire-spokes**
   `action=rollback` for every wired target, then **destroy-lab**. Its `snet-labfw` and the spoke route tables
   `rt-labfw-*` would otherwise collide with the ones this repository creates (same subnet, and a subnet holds one
   route table). Its bootstrap resources (`rg-labfw-<region>`, the VM identity, the OIDC app) are not used here.
2. `scripts/set-network-mode.sh labfw`, set `labfw` in `stacks/platform-extensions/terraform.tfvars` if the
   defaults do not fit (release, VM size, VPN peers; `operator_principal_ids` with azure-lab-fw's OIDC app keeps
   its Run Command workflows - upgrade-lab, view-logs, e2e-lab, power-lab - working once its `LABFW_RG` points
   at `rg-hub-labfw-<region>`), commit, run **Platform**.
3. The runners now egress through labfw: anything they need beyond `rcg-build-tenant` (in the parent policy)
   is denied and logged (azure-lab-fw **view-logs**, or `labfw logs --action deny` on the VM).
4. aks-terraform's cells follow with their `hub` setting (peering, route tables, DNS): Deploy `dev-shared`, then
   the cells. AKS's outbound type cannot change on a running cluster, so a cell is built again. What the cells
   reach is the parent's `rcg-platform` (AKS FQDN tag, the API servers by the region's `AzureCloud` tag, the
   platform's chart and image sources: `platform_source_fqdns`) and the exposure's child policy.

The cells' public load balancers do not work behind labfw (answers leave by the default route, not the load
balancer: asymmetric routing), so an internal cell has no public entry point - no platform gateway and no Flux
webhook (Flux polls every minute).

Back to `sandbox` or on to `firewall`: switch the mode and run Platform - the route tables, labfw and its subnet go,
and `firewall` mode reuses the same policies once it associates them (backlog item #2).

#### Hybrid: the policy here, labfw elsewhere

labfw also runs outside Azure - on a laptop's Hyper-V or any Linux VM (azure-lab-fw: `platform: generic`,
`deploy/hyperv`) - and still enforces the Firewall Policies of this landing zone, read over HTTPS from ARM. This
needs no network mode: list the outside instance's identity (an Azure Arc machine identity, or a certificate
service principal) in `labfw_hybrid_reader_principal_ids` of `stacks/platform-extensions`. It gets Reader on
`rg-hub-fwpolicy-<region>` (the policies and their IP groups) and the custom role *OneK8s labfw Service Tag
Reader* on `sub-hub`, nothing else.

#### VPN for machines outside Azure

`labfw.vpn.enabled = true` turns on WireGuard on labfw (UDP 51820, the NSG allows `labfw.vpn.source_prefixes`).
Each client creates its own key pair (`wg genkey | tee key | wg pubkey`, or `labfw vpn keygen`) and is listed with
its **public** key and one address of the pool (default 10.0.12.0/24, free inside the hub's 10.0.0.0/16):

```hcl
labfw = {
  release_version = "v0.2.0" # the default; the first release with the VPN
  vpn = {
    enabled = true
    peers = [
      { name = "agent-1", public_key = "<client public key>", allowed_ips = ["10.0.12.10/32"] },
    ]
  }
}
```

The pool counts as management: it is in `ipg-mgmt`, `rcg-build-tenant` lets it reach the API server private
endpoints (443) and the jump host (22), and labfw SNATs its traffic to private destinations (private endpoints
answer the source directly, past any route table), so the NSGs see labfw's address. The client's tunnel carries
only the hub, management and client prefixes (split tunnel) and uses labfw as DNS server, which resolves the hub's
private link zones. The output `labfw` of the extensions apply job names the endpoint; on the VM
`labfw vpn client-config --peer agent-1 --endpoint <endpoint>` prints the client configuration (with a placeholder
for the client's private key). Peers can also be added without a Platform run with azure-lab-fw's
**vpn-peer** workflow (`labfw vpn peer add` on the VM): they go to `/var/lib/labfw/vpn-peers.json` and stay
there across Platform runs, which only rewrite the Terraform list in `config.yaml`.

## 0. Prerequisites

- A new Entra ID tenant (the build tenant) with three subscriptions: `sub-mgmt`, `sub-hub`, `sub-aks-dev`.
- An operator account with Owner on the three subscriptions and on the Tenant Root Group for the bootstrap
  ([accelerator prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/)).
- PowerShell 7.4+, Azure CLI, Terraform 1.12+, Git, and the ALZ module:
  ```powershell
  Install-PSResource -Name ALZ
  ```
- Admin rights on this repository (environments, variables, secrets).
- The platform's one DNS domain, `onek8s.lol` (`dns_domain` in `environments/dev`), never the corporate one. Its
  zone is [aks-terraform](https://github.com/onek8s/aks-terraform)'s, public or private (`dns_zone_private`
  there); the lab's is the public zone of step 3b, which Let's Encrypt validates against.
- vCPU quota in the region for the system pools and the zones' node pool VM families (the lab: Daldv6 8,
  low-priority 3), and an availability zone the subscription may use.

## 1. Fill in the IDs

Replace the placeholder subscription IDs (`00000000-0000-0000-0000-00000000000{1,2,3}`) and check the names in:

| File | What |
|---|---|
| [`accelerator/config/inputs.yaml`](../accelerator/config/inputs.yaml) | `subscription_ids`, `bootstrap_subscription_id`, `bootstrap_location`, the GitHub repository in `federated_credentials` |
| [`accelerator/config/platform-landing-zone.tfvars`](../accelerator/config/platform-landing-zone.tfvars) | `subscription_id_aks_dev`, `defender_email_security_contact`, address prefixes |
| [`stacks/platform-extensions/terraform.tfvars`](../stacks/platform-extensions/terraform.tfvars) | the same subscription IDs |
| [`environments/dev/*.tfvars`](../environments/dev) | the same subscription IDs, `name_suffix` (globally unique Key Vault names), `container_registry_name` in `policy.tfvars` (the registry aks-terraform creates), `dns_domain`, `admin_group_object_ids` |

Choose the network mode (see above, e.g. `scripts/set-network-mode.sh sandbox` for a lab). Then regenerate the
accelerator output and commit:

```bash
scripts/sync-platform.sh
git add -A && git commit -m "Set build tenant IDs" && git push
```

## 2. Bootstrap with the accelerator

From the repository root, signed in to the build tenant (`az login --tenant <build tenant>`):

```powershell
Deploy-Accelerator `
  -inputs "./accelerator/config/inputs.yaml", "./accelerator/config/platform-landing-zone.tfvars" `
  -starterAdditionalFiles "./accelerator/config/lib" `
  -output "./accelerator/output"
```

The `alz_local` bootstrap creates in `sub-mgmt`:

- the intermediate root management group `alz` and moves `sub-mgmt` and `sub-hub` under it,
- the Terraform state storage account (Entra ID auth only) and container,
- the managed identities `id-alz-build-<region>-plan-1` (Reader) and `id-alz-build-<region>-apply-1`
  (Owner) on `alz`, federated with the GitHub environments `platform-plan` / `platform-apply`,

and writes the starter module into [`platform/`](../platform). `git diff platform/` should be empty apart from
the generated `scripts/deploy-local.ps1` (not used: the GitHub workflows deploy). If the accelerator wrote other
differences, commit them and align `scripts/sync-platform.sh`, which CI uses to keep `platform/` and
`accelerator/config` in sync.

Note the names of the state resource group, storage account and container and the client IDs of the two
identities from the bootstrap output. Keep `accelerator/output` (the bootstrap's own local state).

The GitHub OIDC subjects in `inputs.yaml` (and `github_oidc_subject_prefix` of the platform extensions) must
match the repository's token subject, which for new organizations contains the immutable owner and repository
IDs: `gh api repos/onek8s/azure-landing-zone/actions/oidc/customization/sub`.

Do not apply the bootstrap again once the platform has run: it would move `sub-mgmt` and `sub-hub` back from
`management` / `connectivity` to `alz`. To change only the federated credentials, plan the bootstrap with
`-target='module.azure[0].azurerm_federated_identity_credential.alz["github_platform_plan"]'` (and `_apply`).

## 3. Put sub-aks-dev under the hierarchy

The platform places `sub-aks-dev` into the `corp` management group (`subscription_placement.aks_dev`), which the
apply identity can only do once the subscription is below `alz`:

```bash
az account management-group subscription add --name alz --subscription <sub-aks-dev>
```

## 3b. Public DNS zone

The public zone `onek8s.lol` is created once, outside Terraform, so that a lab reset or a rebuilt stack never
changes its name servers (the registrar points at them). It lives in `rg-onek8s-dns` in `sub-aks-dev`, which the
Lab reset keeps; [aks-terraform](https://github.com/onek8s/aks-terraform) only looks it up and lets each
cluster's external-dns write its own records.

```bash
az group create --subscription <sub-aks-dev> -n rg-onek8s-dns -l swedencentral --tags purpose=public-dns  # a DNS zone is global; the group stays where it was created
az network dns zone create --subscription <sub-aks-dev> -g rg-onek8s-dns -n onek8s.lol
az network dns zone show --subscription <sub-aks-dev> -g rg-onek8s-dns -n onek8s.lol --query nameServers
```

Set the four name servers as the domain's NS records at the registrar.

## 4. GitHub environments, variables and secrets

Repository **variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `BACKEND_AZURE_RESOURCE_GROUP_NAME` | state resource group from step 2 |
| `BACKEND_AZURE_STORAGE_ACCOUNT_NAME` | state storage account from step 2 |
| `BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME` | state container from step 2 (`build-tfstate`) |
| `RUNNER_APP_ID` | optional: GitHub App for runner registration |

Repository **secrets**: `RUNNER_REGISTRATION_TOKEN` – a fine-grained PAT for this repository with
*Administration: read and write* (or `RUNNER_APP_PRIVATE_KEY` with `RUNNER_APP_ID`). It is only used to register
the self-hosted runners.

**Environments** – each with the variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`:

| Environment | Protection | `AZURE_CLIENT_ID` | `AZURE_SUBSCRIPTION_ID` |
|---|---|---|---|
| `platform-plan` | – | plan identity from step 2 | `sub-mgmt` |
| `platform-apply` | required reviewers, branch `main` | apply identity from step 2 | `sub-mgmt` |
| `aks-dev-plan` | – | from step 6 output `aks_environment_identities` | `sub-aks-dev` |
| `aks-dev-apply` | required reviewers, branch `main` | from step 6 output | `sub-aks-dev` |

Protect `main` with a ruleset (pull request required, status checks of the **CI** workflow).

## 5. What runs where

| Workflow | Root module | State key | Runner | Identity |
|---|---|---|---|---|
| Platform | `platform` | `terraform.tfstate` | GitHub-hosted | accelerator plan / apply |
| Platform | `stacks/platform-extensions` | `platform-extensions.tfstate` | GitHub-hosted | accelerator plan / apply |
| AKS policy | `stacks/aks-policy` + `environments/dev/policy.tfvars` | `aks-dev-policy.tfstate` | GitHub-hosted | `id-aks-dev-plan` / `-apply` |
| onek8s/aks-terraform Deploy | `shared/`, the repository root + `envs/dev-<cluster>.tfvars` | `<stack>.tfstate` in `sub-aks-dev` | GitHub-hosted | `id-aks-dev-apply` (GitHub environment `dev` there) |

The dev lab's API servers are public (Entra ID only, local accounts disabled), so nothing of the clusters needs the
self-hosted runners.

## Lab SKUs

The build tenant runs with the cheapest SKUs that keep the design working. Each one is a single switch back to
the design:

| Component | Lab (default) | Design | Switch |
|---|---|---|---|
| Jump host, test client | not deployed – use `az aks command invoke` or the runners | Linux VMs reached through Bastion | `jump_host_enabled` / `client_vm_enabled` in `stacks/platform-extensions`, together with `primary_bastion_enabled = true` |
| Bastion | not deployed | Standard | `primary_bastion_enabled` in `accelerator/config/platform-landing-zone.tfvars` |
| Azure Firewall (`firewall` mode) | Standard, no IDPS | Premium, IDPS | `primary_firewall_sku_tier` and `intrusion_detection` in the accelerator config |
| GitHub runners | 1 | 2 | `github_runners.count` |
| Runner ACR | Basic, public endpoint, Entra ID authentication only | Premium, private endpoint | `runner_registry_sku` |
| Environment ACR | not part of the landing zone: created by [aks-terraform](https://github.com/onek8s/aks-terraform) (`shared/`). Basic, public endpoint, Entra ID authentication only in every non-production environment (design D62) | Premium, private endpoint, no public network access in prd | aks-terraform `shared/` `container_registry_sku` (defaults from the environment); `firewall_exposures.<exposure>.container_registry` in `stacks/platform-extensions` for the Firewall rule of a public registry (null with a private endpoint) |
| Key Vaults | standard, software-protected cluster keys (RSA) | premium, RSA-HSM | aks-terraform `shared/` – changing it later replaces the cluster keys, so rebuild the cells |
| Traffic Manager | one profile per external hostname | the same | aks-terraform `shared/`: `global_hostnames` |
| AKS | Free tier, 1 system node, public API server | Standard tier, 3 system nodes, private API server | `sku_tier`, `default_node_pool.node_count`, `private_cluster_enabled` in aks-terraform's `envs/dev-ext-stateless-az*.tfvars` |
| Monitoring | none for now - observability is set up later: no Log Analytics, no Container Insights, no VM Insights, no diagnostic settings | Log Analytics, Container Insights, control plane diagnostics (no Defender: a third-party security tool, design D81) | to be designed with the observability stack ([section 6.2](https://onek8s.github.io/design/6.2-observability-with-grafana-cloud.html)) |
| Private link DNS zones | Key Vault and ACR only | all ~90 ALZ zones | `private_link_private_dns_zones` in the accelerator config (remove it for all zones); add a zone there and in `modules/platform-lookup` before a stack uses it |
| Private DNS Resolver | not deployed – sandbox spokes use Azure DNS with the hub zones linked | inbound endpoint for the corporate DNS forwarders | `primary_private_dns_resolver_enabled` in the accelerator config |
| Runner image registry | only while runners exist – without them the environment ACR of aks-terraform is the only registry | Premium, private endpoint | `github_runner_token` / `github_runner_app_*`, `runner_registry_sku` |
| Management VNet NAT gateway | only while runners or the jump host exist | always (sandbox mode) | follows `github_runner_token` / `github_runner_app_*` and `jump_host_enabled` |
| Management resources | not deployed (`management_resources_enabled = false`), and the ALZ assignments that need them removed in `accelerator/config/lib` (activity log, diagnostics, SQL auditing, Defender for Cloud export, the AMA VM / VMSS / Arc monitoring and change tracking) | Log Analytics workspace, Azure Monitor Agent identity, VM data collection rules, those assignments | `management_resources_enabled` and `management_resource_settings` in the accelerator config, the overrides in `accelerator/config/lib/archetype_definitions` |
| ALZ policy assignments | only those for what the AKS platform runs on (AKS, compute and disks, networks, Key Vault, container registry, storage, encryption); every Defender for Cloud / Defender for Endpoint assignment, the guardrails of services the platform does not use, VM operations and generic governance removed in `accelerator/config/lib` (2026-10-19). The build tenant's own non-AKS resources - the bootstrap state account, the management and hub subnets, labfw - are exempt from the platform guardrails (`stacks/platform-extensions` `main.policy.exemptions.tf`) | the same, without the labfw exemptions | the overrides in `accelerator/config/lib/archetype_definitions`, `PARAMETERS` in `scripts/generate-policy-enforcement.py` |
| Key Vault purge protection policy | not assigned (dev and acc vaults are rebuilt with their cells) | assigned in prd | `stacks/aks-policy` (`environment`) |

Destroy the cells (aks-terraform: Actions → Deploy → a cell, `destroy`) when they are not needed: they are the
largest cost of the lab.
Acceptance testing (phase 3) runs with the design values.

## 6. Platform

Run the **Platform** workflow (Actions → Platform → Run workflow), approve the two apply jobs. It deploys:

- management groups and all ALZ policy assignments with `enforcementMode: DoNotEnforce`,
- the hub in `sub-hub`: the private link DNS zones, plus Azure Firewall (DNS proxy) in `firewall` mode and Bastion when enabled,
- the management VNet with an ACI GitHub runner and its image registry when a runner token or GitHub App is set
  (the jump host only when enabled), the client VNet (the test
  client only when enabled), the Firewall rule collection groups and the dev deployment identities.

`environments.<env>.deployment_repositories` federates the apply identity with other repositories too:
`onek8s/aks-terraform` deploys the clusters and the container registry into `sub-aks-dev` from its GitHub
environment `dev` (variables `AZURE_CLIENT_ID` = the `aks-dev-apply` client ID, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`; no secret).

Copy the client IDs from the output `aks_environment_identities` of the extensions apply job into the
`aks-dev-plan` / `aks-dev-apply` environments – the **AKS policy** workflow needs only these.

Until `BACKEND_AZURE_STORAGE_ACCOUNT_NAME` is set the Platform workflow skips its jobs, so pushes before the
bootstrap stay green.

## 7. dev environment and cells

Run the **AKS policy** workflow (also on every change to `stacks/aks-policy`): it assigns the AKS policies to
`sub-aks-dev`, where every cluster with the Azure Policy add-on reports its compliance. Then deploy the clusters
from [onek8s/aks-terraform](https://github.com/onek8s/aks-terraform): its **Deploy** workflow applies `dev-shared`
(the cells' networks, the platform and zone Key Vaults, the internal zones' private DNS, the container registry,
Traffic Manager) and then the cell, `dev-int-stateless-az3`; its **Renew Certificate**
workflow issues the gateways' certificates. A cell takes roughly 15–20 minutes. Its **Cluster status** workflow
reports what runs inside a cell.

## 8. Phase 1 exit criterion: create and delete a cell by the pipeline

aks-terraform: Actions → **Deploy** → `dev-int-stateless-az3`, `destroy`. Then the same with `apply` and
`allow_empty_state`: the cell is rebuilt from IaC (new OIDC issuer, federated credentials replaced, its keys
created again in the platform vault) and Flux brings back everything inside it.

## Lab reset

When the lab is broken beyond repair, Actions → **Lab reset** removes everything the platform and AKS stacks
created – resource groups, policy assignments and definitions, the ALZ custom roles, the management groups below
`alz` – and then their Terraform state, so the next Platform run deploys from scratch. The subscriptions, the
accelerator bootstrap (state storage, plan / apply identities, the `alz` management group), the public DNS zone
`onek8s.lol` (resource group `rg-onek8s-dns` in `sub-aks-dev`, created once with the Azure CLI and delegated at the
registrar, so its name servers must not change) and the GitHub settings stay. It runs with the platform apply identity, so its reviewers approve it.

- Type `reset-lab` in *confirm*. *dry_run* (default) only lists what would be deleted.
- *skip_policies* (default on) keeps the management groups below `alz`, Azure Policy (assignments, exemptions,
  definitions, the policy identities' role assignments), the ALZ custom roles and their Terraform state
  (`terraform.tfstate`, `aks-*-policy.tfstate`): their removal takes most of a reset's time. Turn it off for a reset
  from scratch.
- Resource groups that other repositories created in the subscriptions go too - e.g. azure-lab-fw's
  `rg-labfw-<region>` with the VM identity its repository variables name: run its **azure-bootstrap** again
  afterwards (its OIDC app survives, its role assignments do not).
- Deletions run in passes: a failure is logged and retried in the next pass. The Terraform state is deleted only
  when nothing is left; otherwise the run fails with the list of leftovers and can simply be started again.
- *redeploy* starts the Platform workflow afterwards; run AKS policy and aks-terraform's Deploy after it.
- Key Vaults with purge protection (aks-terraform's platform vault) stay soft-deleted for 90 days and keep their
  names; aks-terraform recovers a soft-deleted vault when it creates it again.

## Phase 3: switch from audit to deny

Before acceptance testing every policy goes to its production effect (requirements 0.3, "Switch policies to deny first"):

- `policy_enforcement_mode = "Default"` in `accelerator/config/platform-landing-zone.tfvars` (then
  `scripts/sync-platform.sh`) and in `environments/dev/policy.tfvars`,
- in `stacks/aks-policy`, the definitions still at effect `Audit` move to `Deny` one by one,
- the design SKUs (see [Lab SKUs](#lab-skus)), in particular Firewall Premium with
  `intrusion_detection.mode = "Deny"` and `threat_intelligence_mode = "Deny"` in the Firewall policy,
- external applications are reached through Azure Traffic Manager (aks-terraform), which has no WAF; a WAF in front of the
  external zones is an open question of the design.
