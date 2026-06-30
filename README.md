# BugRaid AI — Private Connectivity

Private network connectivity between **your network** and **BugRaid AI's AWS account**, so BugRaid's `melt-fetcher` can read telemetry from internal tools (Grafana, Prometheus, Jira Server, GitHub Enterprise Server, OpenSearch, etc.) that aren't exposed to the public internet.

Two patterns supported, depending on where your tools live and how many you want to expose. See **[docs/decision-tree.md](docs/decision-tree.md)** to pick the right one for you.

| Pattern | Best for | Customer effort | BugRaid cost |
|---|---|---|---|
| **Reverse PrivateLink** (per tool) | 1-3 tools in customer AWS VPC | 1 CFT per tool, ~20 min | ~$19/mo per tool |
| **Site-to-Site VPN** | Many tools, or tools behind corporate firewall / on-prem | IPsec config on existing firewall, ~1 day | ~$220/mo per customer |

For SaaS tools (Datadog, NewRelic, github.com, atlassian.net) — neither pattern applies; use BugRaid's static egress IP allowlist (no AWS setup needed).

## What this gets you

| Before | After |
|---|---|
| Customer publishes internal Grafana to the public internet for BugRaid to reach | Grafana stays VPN-only; BugRaid reaches it over AWS PrivateLink |
| Static IP allowlist on customer firewall | No firewall changes — connection is one-way producer→consumer |
| TLS over the public internet | TLS over the AWS backbone (the AZ-to-AZ fibre AWS owns) |
| Customer-side egress fees on every request | Zero customer egress; consumer pays endpoint hourly + interface-endpoint data |

## Pattern: Reverse AWS PrivateLink

You (the customer) are the **PrivateLink service provider**. Each internal tool you want BugRaid to reach sits behind an internal Network Load Balancer (NLB) inside your VPC. You expose that NLB as a **VPC Endpoint Service** and add BugRaid's AWS account as an allowed principal.

BugRaid (the consumer) creates an **Interface VPC Endpoint** in our VPC that targets your service. Our `melt-fetcher` resolves the tool's hostname privately (via a private hosted zone in our VPC), hits the endpoint, and the connection rides AWS's backbone to your NLB → your tool.

```
+-------------------------------------------+              +-------------------------------------------+
| Customer AWS account (provider)           |              | BugRaid AI AWS account (consumer)         |
|                                           |              |                                           |
|  ┌─────────┐    ┌──────────┐   ┌────────┐ |  AWS         | ┌─────────┐   ┌────────────┐  ┌────────┐  |
|  │ Grafana │ ←─ │ Internal │ ←─│Endpoint│ ←──backbone──→ │Interface│ ←─│melt-fetcher│ │  RCA   │  |
|  │ Jira    │    │ NLB      │   │Service │ |              │Endpoint │   │   ECS task │ │  agent │  |
|  │ Prom…   │    └──────────┘   └────────┘ |              └─────────┘   └────────────┘  └────────┘  |
|  └─────────┘                              |              |                                           |
|  (internal VPC only — no public IP)       |              |                                           |
+-------------------------------------------+              +-------------------------------------------+
                                                                            (one Interface Endpoint per
                                                                             customer per tool — or per
                                                                             customer per multi-port NLB)
```

## Two CloudFormation templates do all the work

| Side | Template | What it creates |
|---|---|---|
| **Customer** (you) | [`templates/customer/reverse-privatelink.yml`](templates/customer/reverse-privatelink.yml) | Internal NLB + Target Group pointed at your tool + VPC Endpoint Service + principal allowlist for BugRaid |
| **BugRaid** | [`templates/bugraid/consumer-endpoint.yml`](templates/bugraid/consumer-endpoint.yml) | Interface VPC Endpoint targeting your service + private hosted zone so melt-fetcher resolves the tool's hostname privately |

Both templates are idempotent and parameterized. Read the [customer runbook](docs/runbook-customer.md) before clicking "Create stack" — it's a 20-minute walk-through.

## Quick start (one tool)

1. **Customer**: open the [customer runbook](docs/runbook-customer.md), fill in the worksheet, deploy `templates/customer/reverse-privatelink.yml`. Send BugRaid the stack output (one line, the **Service Name**).
2. **BugRaid**: open the [BugRaid runbook](docs/runbook-bugraid.md), deploy `templates/bugraid/consumer-endpoint.yml` with the customer's Service Name. Update the customer's integration record in `dev-api` to point at the private endpoint hostname.
3. **Verify**: trigger a chaos-console incident on the customer's service. melt-fetcher CloudWatch should show `<tool>_fetch_started` with the private endpoint hostname.

## Docs

- **[Decision tree](docs/decision-tree.md)** — which pattern fits your setup
- [Architecture](docs/architecture.md) — how Reverse PrivateLink works
- [Customer runbook — Reverse PrivateLink](docs/runbook-customer.md) — step-by-step deploy
- [Customer runbook — Site-to-Site VPN](docs/runbook-s2s-vpn-customer.md) — for VPN-only / on-prem tools
- [BugRaid runbook — Reverse PrivateLink](docs/runbook-bugraid.md) — internal TAM checklist
- [BugRaid runbook — Site-to-Site VPN](docs/runbook-s2s-vpn-bugraid.md) — internal TAM checklist
- [Security FAQ](docs/security-faq.md) — for your security review board
- [Troubleshooting](docs/troubleshooting.md) — common failures and fixes
- [Cost estimate](docs/cost-estimate.md) — concrete numbers per pattern

## Examples

- [Self-hosted Grafana on EC2/EKS](examples/grafana.md)
- [Jira Server / Confluence Server](examples/jira-server.md)
- [GitHub Enterprise Server](examples/github-enterprise.md)
- [Prometheus / Mimir / Thanos](examples/prometheus.md)

## What's NOT covered here

- **SaaS tools** (Grafana Cloud, Atlassian Cloud, github.com, Datadog, New Relic, Sentry) — those don't live in your AWS VPC, so PrivateLink doesn't apply. Use BugRaid's static egress IP allowlist instead (we provide the IP).
- **Tools outside AWS** (on-prem data centre, Azure, GCP) — different pattern (Site-to-Site VPN or Direct Connect partner). Ask your BugRaid contact.
- **Push-based telemetry forwarding** (you running an OpenTelemetry Collector that pushes to BugRaid) — separate runbook, see `bugraid-edal-live` repo.

## Support

- Slack: `#bugraid-onboarding` (your shared channel)
- Issues: file in this repo
- Emergency: page your BugRaid TAM

---

© BugRaid AI. Apache-2.0 licensed templates; internal-only documentation.
