variable "location" {
  type        = string
  default     = "germanywestcentral"
  description = "Region of the platform landing zone (starter_location_01)."
}

variable "subscription_ids" {
  type        = map(string)
  description = "management (sub-mgmt) and connectivity (sub-hub) subscription IDs, the same as in accelerator/config/inputs.yaml."
}

variable "github_repository" {
  type        = string
  default     = "onek8s/azure-landing-zone"
  description = "owner/name of the repository whose GitHub environments get OIDC access."
}

variable "github_oidc_subject_prefix" {
  type        = string
  default     = "repo:onek8s@340519759/azure-landing-zone@1412897246"
  description = "Subject prefix of the repository's GitHub OIDC tokens: owner and repository with their immutable IDs (gh api repos/<owner>/<repo>/actions/oidc/customization/sub)."
}

variable "state_storage_account_name" {
  type        = string
  description = "Terraform state storage account created by the accelerator bootstrap (BACKEND_AZURE_STORAGE_ACCOUNT_NAME)."
}

variable "state_resource_group_name" {
  type        = string
  description = "Resource group of the state storage account (BACKEND_AZURE_RESOURCE_GROUP_NAME)."
}

variable "state_container_name" {
  type        = string
  description = "State container (BACKEND_AZURE_STORAGE_ACCOUNT_CONTAINER_NAME)."
}

variable "management_address_space" {
  type        = string
  default     = "10.0.8.0/22"
  description = "Management VNet (OneK8s design picture 1.1): jump hosts, self-hosted CI runners and the private endpoints to every API server."
}

variable "client_address_space" {
  type        = string
  default     = "10.200.0.0/22"
  description = "Client VNet that simulates the corporate network in the build tenant (OneK8s design section 7.1)."
}

variable "environments" {
  type = map(object({
    subscription_id = string
    countries       = optional(map(number), { fi = 1, se = 2 })
    # Isolation zone => extra FQDNs the zone's applications may reach on the Internet (union of the zones'
    # application egress policies, OneK8s design section 5.1). Platform FQDNs are always allowed.
    zone_fqdn_allow_lists = optional(map(list(string)), {})
    # The environment ACR is public (Basic, created by onek8s/aks-terraform in the lab):
    # firewall mode then allows the nodes and the runners to reach it on the Internet instead of its private endpoint
    public_registry = optional(bool, true)
    # Other repositories that deploy into the environment with its apply identity, keyed by repository name:
    # the GitHub OIDC subject prefix (gh api repos/<owner>/<repo>/actions/oidc/customization/sub) and the GitHub
    # environment of the deploying workflow. onek8s/aks-terraform deploys the clusters and the container registry.
    deployment_repositories = optional(map(object({
      subject_prefix     = string
      github_environment = string
    })), {})
  }))
  description = "AKS platform environments that exist in this tenant. The build tenant only has dev (OneK8s design section 7.1)."
}

variable "jump_host_enabled" {
  type        = bool
  default     = false
  description = "Linux jump host in the management VNet, signed in with Entra ID. Needs the hub Bastion (primary_bastion_enabled in accelerator/config/platform-landing-zone.tfvars). Off in the lab: `az aks command invoke` and the runners reach the private API servers."
}

variable "jump_host_vm_size" {
  type    = string
  default = "Standard_D2s_v6" # new subscriptions have no Dv5 quota by default
}

variable "client_vm_enabled" {
  type        = bool
  default     = false
  description = "Test client / load generator VM in the client VNet (and its NAT gateway in sandbox mode). Needs the hub Bastion like the jump host. Turn on for acceptance testing (OneK8s design section 7.1)."
}

variable "client_vm_size" {
  type    = string
  default = "Standard_D2s_v6" # new subscriptions have no Dv5 quota by default
}

variable "admin_group_object_id" {
  type        = string
  default     = ""
  description = "Entra ID group of the platform team: Virtual Machine Administrator Login on the jump host and test client."
}

variable "github_runners" {
  type = object({
    count = optional(number, 1)
    # Runner image of the ALZ accelerator (accelerator-bootstrap-modules, runner_container_image_*)
    image_repository = optional(string, "https://github.com/Azure/avm-container-images-cicd-agents-and-runners")
    image_ref        = optional(string, "9b4c292e1a23c162d7801e019ab9f7f9099c3682")
    image_folder     = optional(string, "github-runner-aci")
    cpu              = optional(number, 2)
    memory           = optional(number, 4)
  })
  default     = {}
  description = "Self-hosted GitHub runners (Azure Container Instances) in the management VNet; the AKS environment and cell workflows run on them because Key Vault, ACR and the API servers are private."
}

variable "runner_registry_sku" {
  type        = string
  default     = "Basic"
  description = "SKU of the runner image registry. Premium: private endpoint, no public access, zone redundant (the design). Basic / Standard (lab): public endpoint with Entra ID authentication only, no private endpoint."
  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.runner_registry_sku)
    error_message = "Basic, Standard or Premium."
  }
}

variable "github_runner_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Fine-grained PAT with 'Administration: read and write' on the repository, used to register the runners. Leave empty to use a GitHub App instead, or to not create runners."
}

variable "github_runner_app_id" {
  type        = string
  default     = ""
  description = "GitHub App ID for runner registration (alternative to the PAT)."
}

variable "github_runner_app_private_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Private key (PEM) of the GitHub App."
}

variable "tags" {
  type = map(string)
  default = {
    deployed_by = "terraform"
    platform    = "aks"
    tenant      = "build"
  }
}

variable "hub_bastion_subnet_prefix" {
  type        = string
  default     = "10.0.0.64/26"
  description = "AzureBastionSubnet of the hub (primary_bastion_subnet_address_prefix in platform-landing-zone.tfvars)."
}

variable "network_mode" {
  type        = string
  default     = "firewall"
  description = "firewall (design), sandbox (no Azure Firewall: direct peerings, NSGs, NAT gateways) or labfw (sandbox with labfw in the hub instead of Azure Firewall for the management and client VNets) – network-mode.tfvars."
  validation {
    condition     = contains(["firewall", "sandbox", "labfw"], var.network_mode)
    error_message = "firewall, sandbox or labfw."
  }
}

variable "labfw_hybrid_reader_principal_ids" {
  type        = list(string)
  default     = []
  description = "Identities of labfw instances running outside Azure (hybrid: e.g. on Hyper-V, with an Azure Arc machine identity or a certificate service principal) that read the Firewall Policies: Reader on their resource group and the service tag list of sub-hub. Any network mode."
}

variable "labfw" {
  type = object({
    # GitHub release of onek8s/azure-lab-fw; vendor the same ref into modules/labfw (scripts/vendor-labfw.sh)
    release_version = optional(string, "v0.2.0")
    release_repo    = optional(string, "onek8s/azure-lab-fw")
    vm_size         = optional(string, "Standard_B2ats_v2") # 2 vCPU / 1 GiB, the smallest Basv2 size (B1ls is often capacity-restricted)
    arch            = optional(string, "x64")
    subnet_prefix   = optional(string, "10.0.1.0/26") # 10.0.0.0/26 stays free for AzureFirewallSubnet
    # The exposure whose child Firewall Policy (main.firewall.policies.tf) labfw enforces, with the parent
    policy_exposure = optional(string, "ext")
    # Spokes use labfw's DNS proxy as DNS server. Off: Azure DNS with the hub zones linked, as in sandbox mode
    spoke_dns_proxy = optional(bool, false)
    # onek8s/azure-lab-fw's OIDC app: Virtual Machine Contributor on the labfw resource group for its Run Command
    # based workflows (upgrade-lab, view-logs, e2e-lab, power-lab, vpn-peer)
    operator_principal_ids = optional(list(string), [])
    # labfw's connection log in a Log Analytics workspace (modules/labfw logs.tf) - Azure Firewall's diagnostic
    # setting, for labfw: denied connections by default, read by the egress agent (D61) with Reader
    log_analytics = optional(object({
      enabled           = optional(bool, false)
      denied_only       = optional(bool, true)
      retention_in_days = optional(number, 30)
      daily_quota_gb    = optional(number, 1)
      # false: data, queries and the agent's endpoint only through the hub's Azure Monitor Private Link scope
      # (monitor_private_link)
      public_network_access = optional(bool, true)
    }), {})
    # WireGuard for agent and management machines outside Azure: the pool counts as management (ipg-mgmt, the API
    # server private endpoints' NSG). Clients bring their own key pair; only public keys are listed here.
    vpn = optional(object({
      enabled         = optional(bool, false)
      address         = optional(string, "10.0.12.1/24") # gateway address and client pool, free in the hub's 10.0.0.0/16
      listen_port     = optional(number, 51820)
      source_prefixes = optional(list(string), ["Internet"])
      peers = optional(list(object({
        name        = string
        public_key  = string
        allowed_ips = list(string)
      })), [])
    }), {})
    # SSH to labfw (azureuser@<vpn gateway address>) from these VPN client addresses, with these public keys.
    # Empty: SSH closed, Run Command only.
    ssh = optional(object({
      sources         = optional(list(string), [])
      authorized_keys = optional(list(string), [])
    }), {})
  })
  default     = {}
  description = "labfw (onek8s/azure-lab-fw) in the hub, network mode labfw only (main.labfw.tf)."
  validation {
    condition     = var.network_mode != "labfw" || (var.firewall_policies_enabled && contains(keys(var.firewall_exposures), var.labfw.policy_exposure))
    error_message = "network mode labfw enforces the child Firewall Policy of labfw.policy_exposure: turn on firewall_policies_enabled and define that exposure in firewall_exposures."
  }
}

variable "firewall_policies_enabled" {
  type        = bool
  default     = true
  description = "The parent Firewall Policy and a child per exposure (main.firewall.policies.tf, design D53), in every network mode: without an associated Firewall they cost nothing and can be reviewed in the Azure portal."
}

variable "service_tag_region" {
  type        = string
  description = "The region's name in Azure service tags, which is not always its location name (germanywestcentral is `germanywc`, francecentral `centralfrance`): `az network list-service-tags --location <location> --query \"values[?name=='AzureCloud.<guess>'].properties.region\"`."
}

variable "platform_source_fqdns" {
  type = list(string)
  default = [
    # Helm repositories and their chart downloads (GitHub Pages, GitHub releases)
    "charts.external-secrets.io",
    "external-secrets.io", # the chart index's redirect target
    "kubernetes-sigs.github.io",
    "traefik.github.io",
    "grafana.github.io",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    # Upstream images: GitHub Container Registry, Docker Hub, registry.k8s.io (Artifact Registry behind it), Quay
    "ghcr.io",
    "pkg-containers.githubusercontent.com",
    "docker.io",
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
    "production.cloudfront.docker.com", # Docker Hub's layer CDN as well (seen 2026-10-15)
    "registry.k8s.io",
    "cdn.registry.k8s.io", # registry.k8s.io's redirect for image layers (2026)
    "*.pkg.dev",
    "quay.io",
    "*.quay.io",
  ]
  description = "Where the cells' platform components come from (Helm charts and upstream images of aks-fluxcd-platform and aks-terraform gateways/): the parent policy's platform-sources rule for every cell. Drops to the environment ACR once the platform's images and charts are mirrored there."
}

variable "firewall_applications_dir" {
  type        = string
  default     = "firewall-applications"
  description = "The directory, relative to this stack, of the per-application egress files: <env>-<exposure>/<namespace>.yaml (design D61, firewall-applications/README.md)."
  nullable    = false
}

variable "firewall_snat_private_ranges" {
  type        = list(string)
  default     = null
  description = <<DESCRIPTION
The Firewall Policies' SNAT private ranges (design D61): the firewall translates every allowed flow whose destination
is outside them to its own address - public on the internet, private elsewhere. Null keeps Azure's IANA private
ranges (RFC 1918 and 100.64.0.0/10), which leave a flow from a cell to the corporate network untranslated. Name the
landing zone's own ranges (the hub's, the cells') to translate everything that leaves it.
DESCRIPTION
}

variable "firewall_exposures" {
  type = map(object({
    # The internal exposure has the corporate path (the client VNet); every other exposure gets a parent deny to it
    corporate = optional(bool, false)
    # Environment => its cells of this exposure (onek8s/aks-terraform shared/envs/<env>.tfvars, cells.tf)
    environments = map(object({
      system_prefixes = list(string) # every cell's snet-system (and snet-apiserver, if a cell has one)
      # The environment's other networks behind the hub: the private endpoints of its vaults and registry
      # (aks-terraform shared/ private_endpoints), routed through labfw like the cells
      shared_prefixes    = optional(list(string), [])
      platform_key_vault = string
      container_registry = optional(string) # public environment ACR (lab); null with its private endpoint
      # The Grafana collectors' destinations on the Internet (D48); empty with a private endpoint in the hub
      observability_fqdns = optional(list(string), [])
      zones = map(object({
        prefixes  = list(string) # the zone's /24 in every cell: nodes and internal load balancer
        key_vault = string
        # aks-fluxcd-platform policy/egress-allow-lists.yaml: what the zone's applications may reach
        fqdn_allow_list = optional(list(string), [])
      }))
    }))
  }))
  default     = {}
  description = "Exposure (int / ext) => the environments' cells whose rules its child Firewall Policy holds."
}

variable "monitor_private_link" {
  type = object({
    enabled = optional(bool, false)
    # Other Log Analytics workspaces reached through the hub's scope (resource IDs): the AKS environments'
    # (onek8s/aks-terraform shared/ log-<env>-platform). labfw's workspace and endpoint are added on their own.
    workspace_ids = optional(list(string), [])
  })
  default     = {}
  nullable    = false
  description = <<DESCRIPTION
The hub's Azure Monitor Private Link scope (main.monitor.private.tf): one per DNS - its private endpoint (in the
management network's snet-pe) answers every Azure Monitor name for the networks that resolve through the hub, so
there is one for the whole tenant, in access mode Open (resources outside the scope stay reachable on their public
endpoints). The workspaces and data collection endpoints in it can then turn public network access off.
DESCRIPTION
}

variable "bootstrap_state_resource_group_name" {
  type        = string
  default     = "rg-alz-build-state-swedencentral-001"
  description = "Resource group of the ALZ accelerator bootstrap's Terraform state account in sub-mgmt (accelerator/config/inputs.yaml: service alz, environment build, swedencentral, 001), exempt from the platform guardrails (main.policy.exemptions.tf)."
}
