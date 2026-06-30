# Architecture

## Pattern

**AWS PrivateLink, customer-as-provider.** Each internal tool the customer wants BugRaid to read sits behind an internal Network Load Balancer (NLB) in the customer's VPC. The NLB is fronted by an `AWS::EC2::VPCEndpointService` that allowlists the BugRaid AWS account. BugRaid creates an `AWS::EC2::VPCEndpoint` (Interface type) targeting that service. The connection rides AWS's private backbone.

`melt-fetcher` resolves the tool's original hostname (e.g. `grafana.wework.internal`) inside BugRaid's VPC via a Private Hosted Zone that A-records the hostname to the Interface Endpoint's ENI IPs. The HTTPS request goes consumer-ENI → AWS backbone → producer-NLB → tool. TLS terminates at the tool itself (NLB is L4 passthrough), so the tool's existing certificate works unchanged.

## Properties

| Property | Value | Why it matters |
|---|---|---|
| **One-way** | Consumer → producer only. Producer cannot originate connections back to the consumer. | The customer can revoke access at any time without auditing what BugRaid did with the link. |
| **Service-scoped** | Endpoint exposes one NLB only. BugRaid has zero visibility into the rest of the customer's VPC. | Smaller blast radius than VPC peering or Transit Gateway. |
| **No CIDR coordination** | PrivateLink does network address translation at the ENI boundary. Customer and BugRaid VPC CIDRs can overlap. | Saves a re-IP exercise. |
| **No internet exposure** | Endpoint Service is private. The customer's tool can remain bound to a private subnet. | Customer security teams stop asking about "what about the public endpoint we're opening". |
| **TLS end-to-end** | NLB is L4 (TCP) passthrough. The tool's existing cert is used. | Customer doesn't re-issue or share certs. |
| **AWS-native auth** | Allowlist by AWS account ARN. | No new credentials, no key rotation. |
| **Multi-region** | Provider in any region; consumer creates endpoint with `--service-region`. | BugRaid in `ap-southeast-1`, customers anywhere in commercial AWS. |

## Reference topology

```
Customer (provider) AWS account                          BugRaid (consumer) AWS account
ap-south-1                                               ap-southeast-1
┌────────────────────────────────────────────┐           ┌─────────────────────────────────────────────────┐
│                                            │           │                                                 │
│  ┌──────────────────────────────────────┐  │           │  ┌──────────────────────────────────────────┐   │
│  │ VPC vpc-cust (private subnets only)  │  │           │  │ VPC vpc-bugraid                          │   │
│  │                                      │  │           │  │                                          │   │
│  │  ┌────────────┐                      │  │           │  │  ┌────────────────────────────────────┐  │   │
│  │  │ Grafana    │  (10.0.1.42:3000)    │  │           │  │  │ Interface Endpoint (per tool)      │  │   │
│  │  │ EC2/EKS    │  no public IP        │  │           │  │  │ vpce-grafana-wework                │  │   │
│  │  └─────▲──────┘                      │  │           │  │  │ ENI 10.20.5.13, 10.20.5.27 (≥2 AZ) │  │   │
│  │        │                             │  │           │  │  │                                    │  │   │
│  │  ┌─────┴──────┐                      │  │           │  │  │ DNS:                               │  │   │
│  │  │ Target     │ TCP:3000 IP target   │  │           │  │  │   vpce-0xyz.vpce-svc-0abc.         │  │   │
│  │  │ Group      │                      │  │           │  │  │   ap-southeast-1.vpce.             │  │   │
│  │  └─────▲──────┘                      │  │           │  │  │   amazonaws.com                    │  │   │
│  │        │                             │  │           │  │  └────────▲───────────────────────────┘  │   │
│  │  ┌─────┴──────┐                      │  │           │  │           │                              │   │
│  │  │ Internal   │ TCP:3000 listener    │  │           │  │  ┌────────┴──────┐                       │   │
│  │  │ NLB        │ subnets-A, subnet-B  │  │           │  │  │ Route 53      │ Private Hosted Zone   │   │
│  │  │ ≥2 AZs     │                      │  │           │  │  │ grafana.weworkindia.internal:        │   │
│  │  └─────▲──────┘                      │  │           │  │  │   A → 10.20.5.13, 10.20.5.27         │   │
│  │        │                             │  │           │  │  │ (zone attached to vpc-bugraid only)  │   │
│  │  ┌─────┴──────────────────────────┐  │  │           │  │  └──────────────▲───────────────────────┘   │
│  │  │ VPC Endpoint Service           │  │  │           │  │                 │                            │
│  │  │ com.amazonaws.vpce.ap-south-1. │◀─┼──┼─────AWS───┼─────service──────┘                            │
│  │  │ vpce-svc-0abc                  │  │  │  backbone │                                                 │
│  │  │ Acceptance: required           │  │  │  (TCP)    │  ┌─────────────────────────────────────────┐    │
│  │  │ Allowed principal: arn:aws:    │  │  │           │  │ melt-fetcher (ECS Fargate)              │    │
│  │  │   iam::528104389666:root       │  │  │           │  │                                         │    │
│  │  │ Supported regions:             │  │  │           │  │ HTTPS GET https://grafana.              │    │
│  │  │   ap-southeast-1               │  │  │           │  │   weworkindia.internal:3000/...         │    │
│  │  └────────────────────────────────┘  │  │           │  │ (TLS terminates at Grafana itself,      │    │
│  │                                      │  │           │  │  not at the NLB or endpoint)            │    │
│  └──────────────────────────────────────┘  │           │  └─────────────────────────────────────────┘    │
│                                            │           │                                                 │
└────────────────────────────────────────────┘           └─────────────────────────────────────────────────┘
```

## Why this design

### Why NLB and not ALB

AWS only allows `AWS::EC2::VPCEndpointService` in front of NLB or GWLB. ALB is HTTP-aware and would require terminating TLS, which forces the customer to issue a cert for the endpoint DNS and re-architect their tool's auth. NLB at TCP:443 passthrough requires zero changes to the tool itself.

### Why a private hosted zone on the consumer side

If `melt-fetcher` connects to `https://vpce-0xyz.vpce-svc-0abc.ap-southeast-1.vpce.amazonaws.com:3000`, the TLS handshake fails because the tool's cert doesn't cover that name. Options to handle this:

1. **Customer issues a new cert** covering the AWS endpoint DNS — extra customer work, ongoing rotation burden.
2. **NLB terminates TLS** with a cert in the customer's account — customer must issue and rotate, and traffic from NLB to the tool is then plaintext inside the customer's VPC (often unacceptable for HIPAA/PCI).
3. **Private hosted zone on BugRaid's side** aliases the tool's original hostname (e.g. `grafana.weworkindia.internal`) to the endpoint ENIs — **zero changes** to the tool's cert, TLS is end-to-end, melt-fetcher's existing integration config keeps working.

We go with option 3. The customer's hostname might also exist publicly (`grafana.weworkindia.com`); our private hosted zone shadows it only inside BugRaid's VPC, which is exactly what we want.

### Why one tool per stack (V1)

Each `templates/customer/reverse-privatelink.yml` deploy creates a dedicated NLB + Endpoint Service per tool. This is ~$22/mo of NLB cost per tool. A future template will consolidate multiple tools onto one multi-listener NLB to amortise that cost. For V1, one-per-tool is cleaner because:

- Each tool's rollback is independent.
- Naming, tagging and IAM scoping is per-tool.
- Customer can stagger rollout (Grafana first, Jira next week).

When a customer has 5+ tools, talk to your BugRaid TAM about consolidation.

### Why principal allowlist by `:root` ARN

AWS allows scoping `AllowedPrincipals` to a specific IAM user or role, but in practice the BugRaid principal that actually creates the consumer endpoint is the CloudFormation execution role for our `bugraid-private-connect` stack, which may change. `arn:aws:iam::<BUGRAID_ACCOUNT_ID>:root` allows any principal in our account, and BugRaid's account-level guardrails enforce who within that account can create endpoints. The customer's other defences (Acceptance Required, security group on consumer side, TLS auth at the tool) limit what BugRaid can actually do.

## What the customer is **not** trusting BugRaid with

- Customer's VPC route table — unchanged.
- Customer's security groups — unchanged (the NLB only exposes one port).
- Customer's IAM — BugRaid doesn't get an IAM role in the customer's account (cross-account IAM is a separate pattern for tools like CloudWatch).
- Customer's DNS — unchanged. The customer's `grafana.weworkindia.internal` continues resolving to its existing private IP inside their VPC; the new hostname-to-endpoint mapping lives only in BugRaid's private hosted zone.

## What this design explicitly does not protect against

- A misconfigured tool (e.g. Grafana with default admin/admin credentials) — auth is the tool's responsibility, not the network's.
- BugRaid running unauthorised code inside our own account — covered by BugRaid's internal SOC2 controls, not by this design.
- A compromised BugRaid AWS account being used to read customer data — the link is one-way, so the worst case is read of telemetry the customer already chose to expose. The customer can revoke the principal allowlist instantly.

## References

- AWS PrivateLink overview — [docs.aws.amazon.com/vpc/latest/privatelink/](https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html)
- Cross-region PrivateLink (Nov 2024) — [aws.amazon.com/about-aws/whats-new/2024/11/aws-privatelink-cross-region-connectivity/](https://aws.amazon.com/about-aws/whats-new/2024/11/aws-privatelink-cross-region-connectivity/)
- Internal NLB requirements — [docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html)
