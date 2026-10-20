location = "germanywestcentral"
# Its name in service tags (AzureCloud.germanywc)
service_tag_region = "germanywc"

# The same subscriptions as accelerator/config/inputs.yaml – replace
subscription_ids = {
  management   = "2e73156d-6206-4354-b599-1f4e31333a7d" # sub-mgmt
  connectivity = "56b07081-ca7e-4343-b000-bc0998a8c347" # sub-hub
}

# The AKS deployment identities of each environment. dev's apply identity also deploys from onek8s/aks-terraform
# (GitHub environment `dev`): the clusters, the container registry and the public DNS records.
environments = {
  dev = {
    subscription_id = "3b9f032a-0165-4b8c-9e1e-d7a664c661a8" # sub-aks-dev
    deployment_repositories = {
      aks-terraform = {
        subject_prefix     = "repo:onek8s@340519759/aks-terraform@1340382905"
        github_environment = "dev"
      }
    }
  }
}

# state_storage_account_name / state_resource_group_name / state_container_name come from the GitHub variables
# BACKEND_AZURE_* (TF_VAR_*), github_runner_token / github_runner_app_* from GitHub secrets.

# The Firewall Policies (main.firewall.policies.tf, design D53): the prefixes of onek8s/aks-terraform
# shared/envs/dev.tfvars - in every cell snet-system the first /24 slot of its address space and each zone the /24 of
# its index, the pods the /20 of the same index in its pod address space. The lab has the internal exposure and one
# cell, dev-int-stateless-az3 (Sweden's int-se runs there; Finland's int-fi keeps its slots). Disabling or adding a
# country is the zone's entry here, in shared/envs/dev.tfvars (isolation_zones.<zone>.enabled) and in
# environments/dev/policy.tfvars.
# SNAT (design section 5.2): every allowed flow that leaves the landing zone's own ranges - the hub and shared networks
# 10.0.0.0/16 and 172.16.0.0/12, the cells' 10.100.0.0/16 (az3's nodes) and 100.64.0.0/10 - is translated to the firewall's
# address, so no cell address (the az3 pods' 100.64.0.0/16 above all) reaches the corporate network (10.200.0.0/22) or
# the internet.
firewall_snat_private_ranges = ["10.0.0.0/16", "10.100.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]

firewall_exposures = {
  int = {
    # The corporate path: the client VNet reaches the internal zones' gateways
    corporate = true
    environments = {
      dev = {
        # dev-int-stateless-az3: snet-system, which also holds the private API server's Private Link endpoint (reached
        # from the management network and the labfw VPN), and snet-system-pods; the pods keep their own addresses all
        # the way to labfw.
        system_prefixes    = ["10.100.0.0/24", "100.64.0.0/20"]
        shared_prefixes    = ["172.20.2.0/26"] # snet-shared-pe: the vaults', Foundry's and the state account's private endpoints
        platform_key_vault = "kv-onek8s-gwc-platform"
        # Basic, public (design D62): the container-registry rule lets the cells reach its endpoint and its storage
        container_registry = "acronek8sdev"
        # Grafana Cloud (D48) and Grafana's anonymous usage statistics, which Alloy, Beyla and the k8s-monitoring chart
        # report from every node (a platform flow, not an application's: it showed up in both example namespaces'
        # files until 2026-10-17)
        observability_fqdns = ["*.grafana.net", "stats.grafana.org"]
        zones = {
          int-fi = {
            prefixes        = ["10.100.1.0/24", "100.64.16.0/20"]
            key_vault       = "kv-onek8s-gwc-int-fi"
            fqdn_allow_list = ["login.microsoftonline.com"]
          }
          # Sweden: run by az3 - its applications' own destinations are in firewall-applications/dev-int/<namespace>.yaml
          int-se = {
            prefixes        = ["10.100.2.0/24", "100.64.32.0/20"]
            key_vault       = "kv-onek8s-gwc-int-se"
            fqdn_allow_list = ["login.microsoftonline.com"]
          }
        }
      }
    }
  }
}

# labfw (network mode labfw, network-mode.tfvars) in the hub instead of Azure Firewall: it enforces the internal
# exposure's child policy with the parent, and the spokes - the management and client VNets and the AKS cells - use
# its DNS proxy like a Firewall's. The default VM size, Standard_B2ats_v2 (Basv2, 2 vCPU), fits the lab's Basv2
# quota of 4 vCPUs; azure-lab-fw's optional E2E test VM is not deployed here.
labfw = {
  policy_exposure = "int"
  # Its denied connections in Log Analytics (log-labfw-germanywestcentral, table LabfwFirewallLog_CL), where the
  # egress agent (design D61, onek8s/aks-ai-agents) reads them with Reader on sub-hub - no one logs in to the VM
  # No public network access (design D60): the agent ingests and readers query through the hub's Azure Monitor
  # Private Link scope (monitor_private_link) - from outside Azure over the labfw VPN
  # Its summary rules (design D84, defaults on): FirewallDeniedFlows_CL, FirewallRuleHits_CL (hourly), FirewallZoneTraffic_CL (daily)
  log_analytics   = { enabled = true, public_network_access = false }
  spoke_dns_proxy = true
  # WireGuard for machines outside Azure (the pool counts as management: API server private endpoints, jump host,
  # the cells' 443). Each client keeps its own private key; only public keys are listed here.
  vpn = {
    enabled = true
    peers = [
      { name = "olli-1", public_key = "pYIxZlOeS94bjS/n91t2skyVRRRauiwsVpSnXD9gYRI=", allowed_ips = ["10.0.12.10/32"] },
      # aks-terraform's GitHub-hosted runners (kubectl to the private API servers, the private endpoints); its config
      # is the dev environment secret LABFW_VPN_GITHUB_RUNNERS. One peer: those jobs share the concurrency group labfw-vpn.
      { name = "github-runners", public_key = "MPuQuKwgLKKaJ5wiRWanumW+T2EVw6rHLmeDRCcuJgc=", allowed_ips = ["10.0.12.11/32"] },
      # aks-terraform's Deploy workflow, on the VPN for a whole Terraform run (the state, vaults and registry are
      # private); its config is the dev environment secret LABFW_VPN_GITHUB_DEPLOY (VPN clients workflow)
      { name = "github-deploy", public_key = "IeqDBE49fgRByR6GcllmPwCWyTznLsJDRPdNKbpB8Dc=", allowed_ips = ["10.0.12.12/32"] },
    ]
  }
  # SSH to labfw itself over the VPN: ssh azureuser@10.0.12.1 from olli-1 only (not the runners)
  ssh = {
    sources = ["10.0.12.10/32"]
    authorized_keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV0psBSMqZB0V2Ot57JjTm0xB1meG+9cw4JyjaYR9sn user@ai",
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJWJ4Mvd3PInac9Uj68V0Vmk/hexIkYmVRt9109uWcvW administrator@WIN-43251BLNC1M",
    ]
  }
}

# The hub's Azure Monitor Private Link scope (main.monitor.private.tf): labfw's connection log and the AKS
# environments' workspaces reached over Private Link, so that they take no public network access
monitor_private_link = {
  enabled = true
  workspace_ids = [
    "/subscriptions/3b9f032a-0165-4b8c-9e1e-d7a664c661a8/resourceGroups/rg-aks-dev/providers/Microsoft.OperationalInsights/workspaces/log-dev-platform",
  ]
}
