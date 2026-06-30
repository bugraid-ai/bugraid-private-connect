# BugRaid TAM runbook — Site-to-Site VPN onboarding

Internal step-by-step for the BugRaid platform engineer / TAM onboarding a customer who chose S2S VPN. Customer-facing version: [`runbook-s2s-vpn-customer.md`](runbook-s2s-vpn-customer.md).

## Decision gate

Confirm with customer first — S2S VPN is right when **all** are true:

- [ ] Customer's tools are NOT in their AWS VPC (or are in their AWS but they prefer one tunnel over per-tool PrivateLink endpoints)
- [ ] Customer has an existing IPsec firewall with a public IP
- [ ] Customer has ≥3 internal tools to expose (if 1-2, use [reverse PrivateLink](runbook-customer.md) — cheaper, simpler)
- [ ] Customer's CIDR does NOT overlap with BugRaid's `10.250.0.0/16` (dev) or `10.0.0.0/16` (prod)

If any are false → recommend reverse PrivateLink instead.

## Pre-flight: collect 4 must-haves from customer

Ask customer (send them the email template at the bottom of `runbook-s2s-vpn-customer.md`):

1. Public IP of their firewall
2. BGP ASN (or "we don't support BGP")
3. Firewall vendor + model
4. Internal DNS server IP

Plus 2 nice-to-haves:
5. Their AWS region (for cross-region awareness)
6. List of internal hostnames they want exposed

**Block on these.** Don't deploy the CFT with placeholders.

## Step 1 — Deploy the S2S VPN CloudFormation

```bash
aws cloudformation create-stack \
  --stack-name bugraid-pc-s2s-<customer-slug> \
  --region ap-southeast-1 \
  --template-url https://raw.githubusercontent.com/bugraid-ai/bugraid-private-connect/main/templates/bugraid/s2s-vpn.yml \
  --parameters \
    ParameterKey=CustomerSlug,ParameterValue=<customer> \
    ParameterKey=CustomerFirewallPublicIp,ParameterValue=<their-firewall-public-ip> \
    ParameterKey=CustomerBgpAsn,ParameterValue=<their-bgp-asn-or-65000-for-static> \
    ParameterKey=CustomerCidr,ParameterValue=<their-vpc-cidr> \
    ParameterKey=UseStaticRoutes,ParameterValue=<false-for-bgp-true-for-static> \
    ParameterKey=CustomerDnsDomain,ParameterValue=<their-internal-domain> \
    ParameterKey=CustomerDnsServerIp,ParameterValue=<their-dns-server-ip> \
    ParameterKey=BugRaidVpcId,ParameterValue=vpc-0b4a57d4d87587a65 \
    ParameterKey=BugRaidVpcCidr,ParameterValue=10.250.0.0/16 \
    ParameterKey=BugRaidPrivateSubnetIds,ParameterValue=\"<subnet-a>,<subnet-b>\" \
    ParameterKey=BugRaidRouteTableIds,ParameterValue=\"<rtb-a>,<rtb-b>\"

aws cloudformation wait stack-create-complete \
  --stack-name bugraid-pc-s2s-<customer-slug> --region ap-southeast-1
```

Stack creates in ~5 min (VPN connection provisioning is the slowest resource).

## Step 2 — Get stack outputs

```bash
aws cloudformation describe-stacks \
  --stack-name bugraid-pc-s2s-<customer-slug> \
  --region ap-southeast-1 \
  --query 'Stacks[0].Outputs' --output table
```

Save the `VpnConnectionId` — needed for step 3.

## Step 3 — Download the IPsec config file for customer's firewall

Find the vendor's device-type-id at https://docs.aws.amazon.com/vpn/latest/s2svpn/customer-gateway-devices.html. Common ones:

| Vendor | device-type-id |
|---|---|
| Palo Alto PA-series | `paloalto-pa-series-7+` |
| Cisco ASA 5500 | `cisco-asa-5500-ios-12.4+` |
| Cisco ISR | `cisco-isr-ios-12.4+` |
| Fortinet FortiGate (≥6.0) | `fortinet-fortigate-50plus` |
| SonicWall TZ-series | `sonicwall-tz-series-6` |
| Juniper SRX | `juniper-srx-junos-12.x` |
| pfSense | `pfsense-fbsd-2.4+` |
| Generic (no vendor template) | `generic` |

Then:

```bash
aws ec2 get-vpn-connection-device-sample-configuration \
  --vpn-connection-id <vpn-id-from-stack-output> \
  --vpn-connection-device-type-id <vendor-id> \
  --region ap-southeast-1 \
  --output text > customer-<slug>-vpn-config.txt
```

The output is a text file with:
- Pre-shared keys for both tunnels (rotate these out of band if you want stronger key management)
- Tunnel endpoint IPs (AWS-side)
- Phase-1 + phase-2 IPsec parameters
- BGP neighbor config (if BGP enabled)

## Step 4 — Send the config file to the customer

Via Slack to your shared customer channel:

> @<customer-network-lead> — VPN config ready. Attached: `customer-<slug>-vpn-config.txt`.
>
> **What you do:**
> 1. Open in your firewall management UI → import / paste IPsec tunnel config
> 2. Add route on your firewall: `10.250.0.0/16 → VPN tunnel`
> 3. Add inbound rule: allow `10.250.0.0/16:443` to your EKS ingress LB / tool IPs
>
> Both tunnels should come UP in AWS console within ~5 min of you applying the config. Confirm here when done.
>
> Pre-shared keys are in the file. Rotate if your policy requires fresh keys.

## Step 5 — Verify tunnel UP

After customer applies config:

```bash
aws ec2 describe-vpn-connections \
  --vpn-connection-ids <vpn-id> \
  --region ap-southeast-1 \
  --query 'VpnConnections[0].VgwTelemetry'
```

Expect both tunnels with `Status: UP`. If one is UP and the other is DOWN, that's normal during initial bring-up — the second usually comes up within 30 sec.

If both still DOWN after 5 min:
- Customer's pre-shared key mismatch (re-check the config they applied)
- Customer's firewall blocking outbound UDP 500 + 4500 (IKE + NAT-T)
- Customer's public IP changed (NAT'd, dynamic IP, or wrong value provided)

## Step 6 — Verify DNS forwarding works

From a melt-fetcher Fargate task (use ECS Exec):

```bash
aws ecs execute-command \
  --cluster bugraid-dev-ai-ml \
  --task <task-id> \
  --container melt-fetcher \
  --interactive --command "/bin/sh"

# Inside the task:
nslookup grafana.<customer-domain>
# → should return an IP inside the customer's CIDR
```

If `NXDOMAIN`: Resolver rule not associated, OR customer's DNS server isn't reachable through the tunnel.

If returns a public IP: Resolver rule is missing or the wrong domain.

If returns an IP in customer CIDR but `curl` fails: customer's firewall isn't allowing inbound from `10.250.0.0/16` on the port, OR static route wasn't added.

## Step 7 — End-to-end test

```bash
# From melt-fetcher Fargate
curl -v https://grafana.<customer-domain>
# Expect 200 / 302 / 401 / 403

# Or for OpenSearch:
curl -v -u <api-key> https://search.<customer-domain>/_cluster/health
```

If TLS handshake completes against the customer's existing cert, you're done.

## Step 8 — Update dev-api integration records

For each tool the customer wants exposed:

```
PATCH /api/v2/integrations/<integration-id>
{
  "credentials": {
    "endpoint": "https://grafana.<customer-domain>",
    ... (rest unchanged)
  }
}
```

melt-fetcher's adapter code is unchanged — it just sees a different hostname.

## Step 9 — Trigger a test incident

Use chaos-console or the existing wework test payload. Watch:

- `/ecs/bugraid-dev-ai-ml/melt-fetcher` for `grafana_fetcher_initialized: ... endpoint=https://grafana.<customer-domain>`
- `grafana_logs_fetched: ... rows>0`
- No `connection refused` / `DNS resolution failed`

If all three: ✅ you're live.

## Step 10 — Track in customer-onboarding tracker

- Customer × pattern (s2s-vpn)
- VPN connection ID
- Tunnel endpoint IPs
- Customer firewall vendor + ASN
- DNS domain forwarded
- Date live
- Monthly cost

## Rollback

```bash
aws cloudformation delete-stack \
  --stack-name bugraid-pc-s2s-<customer-slug> \
  --region ap-southeast-1
```

Removes VGW, CGW, VPN connection, Resolver endpoint + rule. melt-fetcher's next DNS query for `*.<customer-domain>` returns NXDOMAIN.

Optionally tell customer to remove their firewall config too (the tunnels will simply not come up on next reconnect; idle is fine).

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Stack stuck at `CREATE_IN_PROGRESS` on VPN connection | AWS provisioning is slow; sometimes takes 8-10 min | Wait, don't cancel |
| Stack fails with "CIDR conflict" | Customer CIDR overlaps with BugRaid VPC | Stop, switch to PrivateLink (NAT-protected) instead |
| Stack fails creating Resolver endpoint with "Subnet AZ conflict" | Need 2 subnets in DIFFERENT AZs | Pick subnets from different AZs |
| Tunnel stays DOWN after customer applies config | Pre-shared key mismatch, OR customer's outbound UDP/500/4500 blocked | Re-send config (have them confirm both PSKs match), then check their internet egress firewall |
| Tunnel UP but `curl` fails | Customer's inbound firewall rule missing, OR static route missing | Customer adds inbound rule + (if BGP off) static route via tunnel |
| Tunnel UP, `curl` reaches tool, but TLS error | Customer's tool cert doesn't cover the hostname you used | Use the hostname their cert covers (their internal hostname, e.g. `grafana.acme.internal`) |
| DNS resolves to wrong IP | Resolver rule sent query to wrong DNS server, OR customer's DNS server returns wrong record | Verify Resolver rule has correct `TargetIps`; verify customer's DNS server has the record |

## Cost monitoring

Tag every resource with `Customer=<slug>`. Use AWS Cost Explorer with that tag filter to attribute spend.

Typical monthly cost per customer:
- VPN Connection: $36
- Resolver outbound endpoint (2 ENIs): $182
- Data transfer: $5-30 depending on volume
- **Total: ~$220-250/mo per customer**

If a customer's S2S VPN is idle for >30 days (no melt-fetcher traffic), consider tearing it down. The fixed ~$220/mo is significant for a non-paying customer or expired trial.

## Multi-account customers

If the customer has staging + prod and wants BugRaid in both:
- Deploy 2 stacks: `bugraid-pc-s2s-<customer>-staging` and `bugraid-pc-s2s-<customer>-prod`
- Each has its own VGW, CGW, VPN connection, Resolver endpoint
- Different CIDRs typically (staging usually has a different CIDR)
- Different DNS domains optionally

Cost roughly doubles per customer if both environments are connected.
