# Security FAQ

This document answers the questions your security review board will ask. Each answer is short. If you need supporting evidence (AWS docs, audit attestations), the references are at the bottom.

## Trust boundary

**Q: What does BugRaid actually get access to in our AWS account?**
A: Exactly the network path to one TCP port on one internal load balancer per tool you choose to expose. Nothing else. The PrivateLink endpoint service is a one-way producer-to-consumer pipe — BugRaid cannot enumerate, scan, or reach any other resource in your VPC.

**Q: Does BugRaid get an IAM role or any AWS credentials in our account?**
A: No. This pattern uses only AWS PrivateLink, which is a network primitive. There's no cross-account IAM, no STS assume-role, no API key. (Some other BugRaid integrations like CloudWatch use a separate cross-account IAM role with its own permission scope; that is documented separately and never required for the tools onboarded via this runbook.)

**Q: Can BugRaid initiate connections back into our VPC for things outside what we exposed?**
A: No. AWS PrivateLink is unidirectional by design. The endpoint service exposes only the NLB's listener port. The consumer cannot reach anything else in the provider's VPC.

**Q: How do we revoke access?**
A: One CLI command:
```
aws ec2 modify-vpc-endpoint-service-permissions \
  --service-id <id> \
  --remove-allowed-principals arn:aws:iam::528104389666:root
```
Access is revoked in seconds. Or delete the whole CloudFormation stack — irreversible and complete.

## Data plane

**Q: Where does the traffic actually go?**
A: AWS's private backbone (the fibre AWS owns between AZs and regions). It never traverses the public internet. AWS calls this "AWS-internal traffic". You can verify in VPC Flow Logs: traffic appears with the destination set to a `vpce-` prefixed ENI, and the flow records will not show any NAT/IGW hop.

**Q: Is the traffic encrypted?**
A: Yes, end-to-end. The NLB is configured as **TCP passthrough (L4)** — it does NOT decrypt. TLS terminates at your tool itself, using your tool's existing certificate. BugRaid never sees plaintext at any hop.

**Q: Can BugRaid sniff or inject traffic?**
A: No. The PrivateLink ENI is in BugRaid's VPC; the NLB and target are in yours. They communicate over AWS-internal links that customers cannot observe. Encryption is end-to-end (see above) so even AWS itself doesn't see plaintext.

**Q: Does AWS log this traffic somewhere we don't control?**
A: AWS logs the connection metadata (source, destination, bytes) in your VPC Flow Logs (if enabled) and in CloudTrail (`AcceptVpcEndpointConnections`, `CreateVpcEndpointServiceConfiguration`). Payload is never logged by AWS — the NLB doesn't see it (passthrough mode) and AWS doesn't snoop the backbone.

## Identity and auth

**Q: How do we know it's really BugRaid connecting and not someone who stole BugRaid's account ID?**
A: PrivateLink uses AWS principal-based auth at the control plane (creating the endpoint) and AWS account ownership at the data plane (only resources in account `528104389666` can attach to the ENI). An attacker would need either (a) AWS account-takeover credentials inside BugRaid's organization, or (b) compromise of AWS's own multi-tenant network isolation. Neither is achievable from outside.

**Q: Does the connection use mTLS or anything beyond AWS account trust?**
A: The PrivateLink connection itself is authenticated by AWS principal ARN. Above that, your tool's own auth (Grafana basic auth / API token / OIDC / etc.) applies unchanged. Two-layer defense.

**Q: BugRaid is on a SaaS multi-tenant footprint. Can another BugRaid customer see our data?**
A: No. BugRaid runs separate VPCs per environment and uses per-customer credentials inside melt-fetcher. The PrivateLink endpoint is allowlisted to BugRaid's AWS account; once data flows into BugRaid, internal tenant isolation applies. BugRaid's SOC 2 attestation covers the internal isolation controls; ask your TAM for the latest report.

## Compliance

**Q: HIPAA?**
A: AWS PrivateLink is HIPAA-eligible. BugRaid has a BAA with customers in HIPAA scope. The data plane stays inside the AWS backbone, which AWS treats as a covered environment. (See: AWS HIPAA-eligible services list.)

**Q: PCI-DSS?**
A: PCI-DSS doesn't require any specific encrypted-transport primitive beyond TLS, which is already in place end-to-end here. PrivateLink itself is considered an in-scope service when used to transport cardholder data. Confirm with your QSA, but the pattern is well-understood.

**Q: SOC 2 Type 2?**
A: BugRaid's SOC 2 attestation is available on request from your TAM. AWS's SOC 2 covers the underlying PrivateLink, NLB, Route 53, and VPC Endpoint Service primitives.

**Q: GDPR / data-residency?**
A: PrivateLink supports cross-region. If your data must stay in (e.g.) Mumbai, deploy the customer-side stack in `ap-south-1` and leave BugRaid's consumer endpoint in BugRaid's region. Cross-region data transfer is metered separately and routed across AWS's backbone, which is encrypted at the physical layer.

## Operational

**Q: How do we audit what BugRaid actually fetched?**
A: Two layers. (1) Your own VPC Flow Logs show every connection from BugRaid's endpoint ENI — bytes, timestamps, target. (2) Your tool's own access logs (Grafana audit log, GitHub Enterprise audit log, etc.) show every authenticated request, including the username / token BugRaid used.

**Q: What happens if AWS PrivateLink has an outage?**
A: Same as any AWS service degradation. AWS publishes SLAs (99.95% per AZ-region). Failure mode: melt-fetcher's HTTP calls time out, the adapter emits typed `connect_timeout` errors. No data loss because BugRaid doesn't accept telemetry from your tools unless it's actually fetched (it's a pull model).

**Q: What's the ongoing cost?**
A: See `cost-estimate.md`. Roughly $30-50 per tool per month, including the NLB, endpoint hours, and data transfer at typical telemetry volumes.

**Q: What is BugRaid's plan if their AWS account is compromised?**
A: BugRaid runs MFA, SCPs, GuardDuty, CloudTrail forwarding to a separate audit account, and Account-level Service Control Policies that deny risky actions. Detailed plan in the SOC 2 report. From your perspective: the only attack surface exposed by this pattern is what your tool's own auth lets BugRaid see — even a fully compromised BugRaid account cannot exceed that.

## What this design does NOT protect against

We list these explicitly so security reviewers see we're not over-claiming:

- A misconfigured tool (e.g. Grafana with default admin/admin credentials). The network is private, but the tool's own auth must still be sound.
- BugRaid running unauthorized code inside BugRaid's own AWS account. This is covered by BugRaid's internal controls, not by this design. Customers cannot enforce that BugRaid only runs the agreed-upon code paths — they trust BugRaid's SOC 2 attestation.
- DNS poisoning inside BugRaid's VPC. The Private Hosted Zone is in BugRaid's VPC; if an attacker gains DNS-write access there, they could redirect the tool's hostname. Mitigated by BugRaid's Route 53 IAM scoping.

## References

- [AWS PrivateLink security model](https://docs.aws.amazon.com/vpc/latest/privatelink/privatelink-share-your-services.html#privatelink-allow-principals)
- [AWS HIPAA-eligible services](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/)
- [VPC Flow Logs for PrivateLink](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-records-examples.html#flow-log-example-records-vpc-endpoint)
- BugRaid SOC 2 Type 2 — request from your TAM
- BugRaid BAA template — request from your TAM
