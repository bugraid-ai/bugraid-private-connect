# Customer runbook — Site-to-Site VPN to BugRaid

For customers who need BugRaid's `melt-fetcher` to read from internal tools (Grafana, Prometheus, OpenSearch, internal Jira/GHE Server, etc.) that live behind their corporate firewall or in private AWS subnets.

This pattern uses AWS Site-to-Site VPN — a single IPsec tunnel from BugRaid's AWS account to your existing firewall. One setup covers **all** internal tools reachable from inside your network. No per-tool work.

> **Read first**: [architecture.md](architecture.md) explains the alternatives. **Pick this pattern only if**: (a) you have many internal tools to expose, OR (b) you have an existing IPsec firewall, OR (c) PrivateLink doesn't fit because your tools aren't in AWS VPCs. If you only need to expose 1-2 tools that live in your AWS VPC, the [reverse PrivateLink pattern](runbook-customer.md) is simpler.

## What you need to provide (the 4 must-haves)

Send these to your BugRaid TAM before they can start the setup. Most can be answered by your network / infrastructure team in a few minutes:

| # | Value | Example | Why we need it |
|---|---|---|---|
| 1 | **Public IP of your firewall** | `203.0.113.42` | The IPsec endpoint our AWS VPN tunnel connects to |
| 2 | **BGP ASN** of your firewall | `65500` (private range 64512-65534) | Dynamic routing between AWS and your firewall. If your firewall doesn't support BGP, tell us and we'll use static routes instead. |
| 3 | **Your firewall vendor + model** | "Palo Alto PA-3220", "Cisco ASA 5525-X", "Fortinet FortiGate 100F", "SonicWall TZ470", "Juniper SRX300" | Determines which IPsec config template AWS generates for you |
| 4 | **Internal DNS server IP** | `172.16.46.10` | Where AWS forwards `*.your-domain.com` DNS queries so they resolve to your internal IPs |

Plus 2 more (low effort, helps us prepare in parallel):

| # | Value | Example |
|---|---|---|
| 5 | Your AWS region (where your prod VPC is) | `ap-south-1` |
| 6 | Internal hostnames you want exposed | `grafana.acme.internal`, `jira.acme.internal`, `opensearch.acme.internal` |

## Architecture

```
Your network                              BugRaid AWS account (ap-southeast-1)
─────────────                             ─────────────────────────────────────

  ┌────────────────────┐                  ┌─────────────────────────────────┐
  │ Your VPC / DC      │                  │ BugRaid VPC                     │
  │ <your-cidr>        │                  │ 10.250.0.0/16                   │
  │                    │                  │                                 │
  │ ┌────────────────┐ │                  │ ┌─────────────────────────────┐ │
  │ │ Grafana, Jira, │ │                  │ │ melt-fetcher (ECS Fargate)  │ │
  │ │ OpenSearch...  │◀┼──────IPsec──────▶│ │                             │ │
  │ │ (private IPs)  │ │      tunnel      │ │ HTTPS to                    │ │
  │ └────────────────┘ │   (encrypted)    │ │ grafana.your-domain.com     │ │
  │                    │                  │ └─────────────────────────────┘ │
  │ ┌────────────────┐ │                  │                                 │
  │ │ Your firewall  │ │                  │ ┌─────────────────────────────┐ │
  │ │ (IPsec        )│ │                  │ │ Route 53 Resolver outbound  │ │
  │ │ (BGP optional)│ │                  │ │ Forwards *.your-domain.com  │ │
  │ │ Public IP     │ │                  │ │ to your DNS server          │ │
  │ └────────────────┘ │                  │ └─────────────────────────────┘ │
  │         ▲          │                  │                                 │
  │         │          │                  │ ┌─────────────────────────────┐ │
  │         │          │                  │ │ Virtual Private Gateway     │ │
  │         │          │                  │ │ + VPN Connection (2 tunnels)│ │
  │         └──────────┼──IPsec tunnels───┼─│ → Customer Gateway          │ │
  │                    │  (always 2 for   │ │   (your public IP)          │ │
  │                    │   HA)            │ └─────────────────────────────┘ │
  └────────────────────┘                  └─────────────────────────────────┘
```

## What BugRaid does on its side

1. Creates an AWS Virtual Private Gateway (VGW) attached to BugRaid's VPC.
2. Creates an AWS Customer Gateway (CGW) representing your firewall (uses the 4 values above).
3. Creates the VPN Connection — AWS auto-provisions 2 IPsec tunnel endpoints for high availability.
4. Sets up a Route 53 Resolver outbound endpoint that forwards `*.your-domain.com` queries through the tunnel to your DNS server, so melt-fetcher can resolve hostnames like `grafana.acme.internal`.
5. Generates the IPsec config file for your firewall vendor and sends it to you.

The CloudFormation template that does this is at [`templates/bugraid/s2s-vpn.yml`](../templates/bugraid/s2s-vpn.yml). One stack per customer.

## What you (the customer) do

After BugRaid sends you the IPsec config file, your network team does 3 things:

### Step 1 — Apply the IPsec config to your firewall

The file BugRaid sends is auto-generated by AWS specifically for your firewall vendor. It contains:

- Pre-shared keys for both tunnels (2 tunnels for HA)
- AWS-side tunnel IPs (the two endpoints to connect to)
- IPsec phase-1 and phase-2 parameters (encryption, lifetime, DH group)
- BGP neighbor IPs and ASN (if you opted for BGP)

Your network team imports / pastes this into the firewall management UI. Time: ~15-20 minutes for an experienced network engineer.

### Step 2 — Add the route

Add a route entry on your firewall:

```
Destination: 10.250.0.0/16  (BugRaid CIDR)
Next-hop:    VPN tunnel
```

If using BGP, your firewall will learn this dynamically — no manual route needed.

### Step 3 — Open inbound firewall rule

Allow inbound traffic from BugRaid's CIDR on the port(s) you want to expose:

```
Source:      10.250.0.0/16
Destination: <internal-tool-IP> (e.g. EKS ingress LB private IP)
Protocol:    TCP
Port:        443  (or whatever port the tool uses)
```

If you want to expose multiple tools, add one rule per tool's port.

### Step 4 — Confirm tunnels UP

In AWS console (your AWS account isn't involved here — this is on BugRaid's side, but you can confirm via Slack):

```
VPC → Site-to-Site VPN Connections → bugraid-<your-slug>-vpn → Tunnel Details
```

Both tunnels should show **UP** within ~5 min of you applying the config.

## What you do NOT have to do

- ❌ No new IAM roles or AWS service-linked stuff
- ❌ No changes to your existing AWS VPN setup
- ❌ No re-IP of your internal subnets
- ❌ No new TLS certs (your existing internal certs keep working)
- ❌ No DNS changes on your side (your `grafana.acme.internal` keeps resolving to whatever it does today)
- ❌ No agent or software installed in your environment

## Security model

| Property | Value |
|---|---|
| Encryption | End-to-end IPsec (AES-256 default), plus your tool's own TLS on top |
| Direction | Bidirectional L3 routing (BugRaid ↔ your network) — but BugRaid only initiates outbound to your tools; we don't open listening services on our side |
| Scope of access | Only IPs / ports your firewall allows inbound from `10.250.0.0/16` |
| Auth | IPsec pre-shared keys + BGP (or static routes) + your tool's own auth (bearer tokens, API keys, etc.) |
| Revocation | Tear down the IPsec tunnels on your firewall (instant). Or BugRaid can delete the AWS-side VPN connection. |
| Audit | AWS VPC Flow Logs (BugRaid side) + your firewall logs (your side) |
| Compliance | HIPAA / PCI / SOC 2 — Site-to-Site VPN is in scope for all three |

## Cost (your side)

| Component | Cost |
|---|---|
| Your existing firewall — no change | $0 (already running) |
| Extra firewall config (one-time labor) | One engineer hour |
| Egress bandwidth to AWS | Already part of your existing internet egress |

## Cost (BugRaid side)

| Component | Cost |
|---|---|
| Virtual Private Gateway | $0 (free) |
| Site-to-Site VPN Connection | $0.05/hour ≈ $36/mo (covers both tunnels) |
| Route 53 Resolver outbound endpoint (2 ENIs) | $0.125/ENI/hour × 2 = $182/mo |
| Data transfer out (cross-region if applicable) | $0.02/GB |
| **Total BugRaid side** | **~$220/mo per customer** |

The Resolver endpoint is the largest line — it's only needed if you want to expose multiple hostnames via DNS resolution. For a single tool with a static IP, we can skip the Resolver and hard-code the IP, saving ~$182/mo. Discuss with your TAM.

## Verification (after both sides are configured)

From a BugRaid melt-fetcher Fargate task, your TAM will run:

```bash
# 1. DNS resolves your hostname privately
nslookup grafana.your-domain.com
# → returns an IP in your CIDR (e.g. 172.16.46.X)

# 2. TLS handshake works against your existing cert
curl -v https://grafana.your-domain.com
# → 200 / 302 / 401 / 403 (depending on tool's auth)

# 3. Re-trigger a test incident
# → BugRaid's RCA should now include data from your Grafana
```

## Rollback

If you ever need to disconnect:

**Customer side (instant)**:
1. Tear down the IPsec tunnels on your firewall (one config change)
2. Remove the inbound firewall rule for `10.250.0.0/16`

**BugRaid side (clean removal)**:
```bash
aws cloudformation delete-stack --stack-name bugraid-pc-s2s-<your-slug>
```

This deletes the VGW, CGW, VPN connection, Resolver endpoint, and rule. melt-fetcher stops being able to resolve your hostnames immediately.

## What this is NOT for

- ❌ SaaS tools (Datadog, NewRelic, Sentry, github.com, atlassian.net) — those need static IP allowlisting, not VPN
- ❌ AWS-native APIs (CloudWatch, X-Ray) — those use cross-account IAM, not VPN
- ❌ One-off single-tool exposures — reverse PrivateLink is simpler and cheaper for that case

## Email template to your network team

Copy-paste into your internal ticket:

> Subject: AWS Site-to-Site VPN tunnel to BugRaid AI (one-time, 30 min)
>
> We're enabling BugRaid AI to read from our internal tools (Grafana, OpenSearch) over an AWS Site-to-Site VPN.
>
> **What I need from you:**
> - Public IP of our IPsec endpoint
> - Our BGP ASN (or confirm if we use static routes only)
> - Vendor + model of the firewall doing IPsec
> - Internal DNS server IP that resolves our internal hostnames
>
> **What you'll do after BugRaid sends the config file (~15 min):**
> 1. Apply the AWS-generated IPsec config (vendor-specific) to add 2 new tunnels to BugRaid's AWS endpoints
> 2. Add a route: `10.250.0.0/16 → VPN tunnel`
> 3. Add an inbound firewall rule: allow `10.250.0.0/16:443` to our EKS ingress LB
>
> Encryption is AES-256 IPsec on the network layer, plus our existing TLS on top. Bidirectional L3 access but BugRaid only initiates outbound. Revocable any time by tearing down our tunnels.
