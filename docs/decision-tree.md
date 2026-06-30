# Which pattern? — Decision tree

BugRaid supports three connectivity patterns. Pick one based on **where your tools live** and **how many you want to expose**.

```
                                ┌─────────────────────────────────────────────┐
                                │ Where do your tools live?                   │
                                └──────────────────┬──────────────────────────┘
                                                   │
              ┌────────────────────────────────────┼─────────────────────────────────┐
              │                                    │                                 │
       ▼ in your AWS VPC                  ▼ on-prem / behind                ▼ SaaS (Datadog,
       (Grafana on EC2, Jira              your corporate firewall          NewRelic, github.com,
       Server in EKS, etc.)               / VPN-only                       atlassian.net, etc.)
              │                                    │                                 │
              │                                    │                                 │
              ▼                                    ▼                                 ▼

      ┌───────────────┐                ┌─────────────────────┐               ┌────────────────────┐
      │ How many      │                │   Site-to-Site VPN  │               │ Static IP allow-   │
      │ tools to      │                │                     │               │ list (BugRaid NAT  │
      │ expose?       │                │ ┌─────────────────┐ │               │ EIP added to your  │
      └───┬───────────┘                │ │ One IPsec tunnel│ │               │ SaaS dashboards)   │
          │                            │ │ between your    │ │               └────────────────────┘
   ┌──────┴──────┐                     │ │ firewall +      │ │
   │             │                     │ │ BugRaid AWS.    │ │              No CFT — just one
   ▼ 1-3 tools   ▼ 4+ tools            │ │ Covers ALL      │ │              IP added to SaaS
                                       │ │ tools at once.  │ │              tool's network ACL.
   ┌─────────────┐  ┌──────────────┐   │ └─────────────────┘ │
   │ Reverse     │  │ Multi-tool   │   │                     │              See: docs/saas-
   │ PrivateLink │  │ shared NLB   │   │ See:                │                   allowlist.md
   │             │  │              │   │ - runbook-s2s-vpn-  │                   (TBD)
   │ One CFT per │  │ One CFT, one │   │   customer.md       │
   │ tool. Best  │  │ NLB, multi-  │   │ - runbook-s2s-vpn-  │
   │ security    │  │ listener.    │   │   bugraid.md        │
   │ posture +   │  │ Cheaper at   │   │ - templates/        │
   │ no CIDR     │  │ scale.       │   │   bugraid/          │
   │ coordination│  │              │   │   s2s-vpn.yml       │
   │             │  │ (TBD —       │   │                     │
   │ See:        │  │ template     │   └─────────────────────┘
   │ - runbook-  │  │ in V2)       │
   │   customer  │  │              │
   │   .md       │  │              │
   │ - templates/│  │              │
   │   customer/ │  │              │
   │   reverse-  │  │              │
   │   private-  │  │              │
   │   link.yml  │  │              │
   └─────────────┘  └──────────────┘
```

## Side-by-side comparison

| Dimension | Reverse PrivateLink (per tool) | Multi-tool shared NLB (V2) | Site-to-Site VPN | SaaS IP allowlist |
|---|---|---|---|---|
| **Customer effort** | 1 CFT per tool, ~20 min each | 1 CFT total, ~30 min | Firewall config, ~1 day | Add 1 IP, ~5 min |
| **Best for tool count** | 1-3 | 4+ | Any (covers all at once) | Any number of SaaS tools |
| **Where tools live** | Customer's AWS VPC | Customer's AWS VPC | Customer's on-prem / VPN-only | Public SaaS |
| **Direction** | One-way (consumer → producer) | One-way | Bidirectional L3 | Outbound only |
| **CIDR coordination** | Not needed (PrivateLink NATs) | Not needed | **Required — no overlap allowed** | N/A |
| **TLS cert handling** | Customer's existing cert (passthrough) | Customer's existing cert | Customer's existing cert | Customer's existing cert |
| **DNS handling** | BugRaid Private Hosted Zone | BugRaid Private Hosted Zone | Route 53 Resolver outbound endpoint forwards to customer DNS | N/A (public DNS works) |
| **Per-customer cost (BugRaid)** | ~$19/mo per tool | ~$19/mo flat | ~$220/mo flat (includes Resolver) | ~$3.60/mo for the EIP, shared |
| **Per-customer cost (customer)** | ~$25/mo per tool | ~$25/mo flat | ~$0 (uses existing firewall) | $0 |
| **Security review framing** | "Expose one port on one NLB" | "Expose N ports on one NLB" | "Allow BugRaid into our network via existing VPN" | "Add 1 IP to allowlist" |
| **Revocation** | Remove principal from allowlist (instant) | Same | Tear down firewall tunnels (instant) | Remove IP from SaaS ACL |
| **Recommended for** | Most enterprise customers in AWS | Customers with many AWS tools | Customers with on-prem heavy stack OR many tools in AWS | All customers, for SaaS tools |

## Real customer examples

| Customer | Setup | Pattern chosen |
|---|---|---|
| **wework** | Grafana in EKS (VPN-only), OpenSearch in private subnets, Jira Cloud, GitHub Enterprise Cloud | S2S VPN for Grafana + OpenSearch, IP allowlist for Jira + GitHub |
| **qubehealth** (hypothetical) | Sentry SaaS, GCP-hosted logs, AWS CloudWatch | Cross-account IAM for CloudWatch, IP allowlist for Sentry, native GCP integration for logs |
| **Mid-market AWS-native** | Grafana on EC2 (publicly reachable), Prometheus in EKS, Datadog SaaS | Reverse PrivateLink for Grafana + Prometheus, IP allowlist for Datadog |
| **Regulated enterprise** | Internal Splunk on-prem, internal Jira Server on-prem, internal GHE on-prem, all behind corporate VPN | S2S VPN (single tunnel covers all 3 tools) |

## Picking algorithm

If you're a customer trying to decide:

1. **Do you have at least one SaaS tool?** → Always need IP allowlist for those (separate from the network patterns)
2. **Are any of your tools NOT in AWS** (on-prem, other cloud)? → **S2S VPN** (required for non-AWS tools)
3. **Are all your tools in AWS, but you have 4+?** → Multi-tool shared NLB (TBD), or S2S VPN if you prefer one tunnel
4. **Are all your tools in AWS, only 1-3?** → **Reverse PrivateLink** (simplest, cheapest)

Still not sure? Ask your BugRaid TAM — they'll review your tool inventory and recommend.

## What's NOT supported

- Transit Gateway — see [why-not-tgw.md](why-not-tgw.md) (TBD; short version: customer security reviews reject the bidirectional L3 trust)
- VPC Peering — same reason as TGW, plus CIDR collision issues
- Direct Connect — overkill cost; use only if customer already has DX for other reasons
