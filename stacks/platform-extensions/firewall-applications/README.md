# Firewall rules per application (design D59)

What each application may reach outside the landing zone, one file per application namespace:
`<env>-<exposure>/<namespace>.yaml` (`dev-int/int-se-example.yaml`). `main.firewall.policies.tf` turns each into
application rules of its environment's rule collection group in the exposure's child Firewall Policy
(`<env>-<exposure>-applications`, priority 400), named `<namespace>-<protocol>-<port>`, from the application's zone
(the zone's IP group: the firewall tells zones apart by their subnets, not applications within one).

```yaml
zone: int-se                      # the zone the namespace is in; the namespace must be <zone>-<app>
contact: https://github.com/onek8s/aks-fluxcd-example/issues
egress:
  - fqdn: api.open-meteo.com       # a name, or *. and a name
    port: 443                      # default 443
    protocol: https                # https (default) or http
    reason: aks-hello's weather forecast (WEATHER_URL)
    evidence: 12 denied flows 2026-10-15 from pod aks-hello-7d9c... (100.64.32.17), labfw deny log
```

The files are written by the egress agent of onek8s/aks-ai-agents: it reads the flows the firewall denied, finds
the pod behind each source address (the pods keep their addresses up to the firewall), and opens
a pull request adding the destination to that application's file. A human of the platform and security reviews
and merges it; the Platform workflow applies it, and labfw (or the hub's Azure Firewall) enforces it within minutes.
