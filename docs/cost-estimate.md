# Cost estimate

Per-tool, per-month, in USD, for Asia-Pacific (Singapore/Mumbai) regions. Costs are AWS list price as of 2026-06-30. Other regions are within ±10%.

## Same-region (BugRaid and customer both in `ap-southeast-1`)

| Component | Owner | Unit | Cost |
|---|---|---|---|
| Internal NLB | Customer | $0.0252/hour × 730 hours | $18.40/mo |
| NLB LCU (load balancer capacity unit) | Customer | $0.008/LCU-hour, ~1 LCU sustained for telemetry pull | $5.84/mo |
| VPC Endpoint Service | Customer | $0.00 (free) | $0.00 |
| Interface VPC Endpoint | BugRaid | $0.013/hour × 730 hours × 2 AZs | $18.98/mo |
| Interface Endpoint data processing | BugRaid | $0.01/GB | varies — typically <$5/mo for telemetry pull |
| **Total same-region** | | | **~$48/mo per tool** |

## Cross-region (customer in `ap-south-1`, BugRaid in `ap-southeast-1`)

| Component | Owner | Unit | Cost |
|---|---|---|---|
| Same as above except endpoint hourly is the same regardless of cross-region | | | $43-50/mo as above |
| Cross-region data transfer (AWS backbone) | BugRaid | $0.02/GB | varies — $5-30/mo depending on volume |
| **Total cross-region** | | | **~$55-80/mo per tool** |

## What "telemetry volume" looks like in practice

For typical BugRaid pull workload (≤100 RCAs/day, each pulling ~10 MB of logs/metrics/traces):

- Daily transfer: ~1 GB per tool
- Monthly transfer: ~30 GB per tool

For aggressive customers (1000+ incidents/day, large log payloads):

- Daily transfer: ~10-50 GB per tool
- Monthly transfer: ~300-1500 GB per tool

Cost scales linearly with the GB number. Even at the high end, total per-tool cost stays under $150/mo.

## Comparison: alternatives we considered

| Pattern | Customer cost | BugRaid cost | Notes |
|---|---|---|---|
| **This: reverse PrivateLink per tool** | ~$25/mo per tool | ~$25/mo per tool | Best one-way isolation. Recommended. |
| VPC Peering | $0 setup | $0 setup | Data transfer at $0.01/GB intra-region. **Customer must accept full bi-directional VPC access** — usually a deal-breaker for enterprise security review. |
| Transit Gateway | $0.05/hour attachment + $0.02/GB | Same | $36/mo/attachment per side. Only makes sense at 10+ customers with shared TGW. |
| Site-to-Site VPN | ~$36/mo per tunnel | ~$36/mo per tunnel | $0.05/hour. Adds IPsec overhead. Use only for non-AWS customers. |
| Direct Connect | ~$200-1500/mo port | Same | Way overpowered for telemetry. Use only if customer already has Direct Connect for another reason. |
| Public internet + IP allowlist | $0 (NAT EIP ~$3.60/mo) | $0 | Free, but the entire reason this repo exists is to avoid this. Acceptable for SaaS tools (Datadog, NewRelic) that have no private alternative. |

## Cost-optimisation playbook

### When a customer has 3+ tools: consolidate to one NLB

A future template (`reverse-privatelink-multi-tool.yml`) will let one NLB front multiple tools on different ports. Same NLB cost ($18.40/mo) covers all tools instead of one each. Saves ~$18/mo per additional tool.

Today (V1) we have one-NLB-per-tool. The reasons for keeping it that way for V1:

- Independent rollback per tool (delete one stack, others unaffected)
- Independent IAM scoping if customer wants per-tool service principals
- Cleaner audit trail in CloudTrail
- We have <5 tools per customer today, so consolidation savings are <$80/mo

When a customer crosses 5+ tools, talk to your TAM about consolidation.

### Idle endpoint cost

Both the NLB and the Interface Endpoint are hourly charges that run whether anyone uses the connection or not. For a customer who tests for a week then goes quiet:

- 1 week active + 3 weeks idle = $43/mo for ~0 GB of useful data

If you anticipate <10 RCAs/month per customer, the per-incident cost approaches "infinite" — at that volume the public-internet+allowlist pattern is more sensible. Reserve PrivateLink for customers with sustained workload or hard private-network requirements.

### What you do NOT pay extra for

- Acceptance / connection-pending overhead — no charge for endpoint connections in pending state.
- Health checks — included in NLB LCU.
- Private Hosted Zone — $0.50/mo flat per zone (negligible, included in BugRaid's overhead).
- TLS overhead — none, because NLB is passthrough.

## Billing visibility

BugRaid tags every resource with:

```
ManagedBy: bugraid-private-connect
Customer: <customer-slug>
Tool: <tool-name>
```

Use AWS Cost Explorer with these tag filters to attribute spend per customer per tool. We surface this in the per-customer onboarding dashboard once it's live.
