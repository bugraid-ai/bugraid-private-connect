# Troubleshooting

The symptom-to-fix table for the common failure modes. Read top to bottom — fixes earlier in the table assume the symptoms above have been ruled out.

| # | Symptom | Likely cause | Fix |
|---|---|---|---|
| 1 | Customer's stack fails at `EndpointServicePermissions` with `InvalidPrincipal` | Wrong BugRaid account ID supplied | Confirm `BugRaidAccountId=528104389666` (prod) or the dev account ID with your BugRaid TAM. Update parameter and re-deploy. |
| 2 | Customer's stack fails at `NetworkLoadBalancer` with `IsolatedAZ` or similar | Subnets passed are not in distinct AZs | `aws ec2 describe-subnets --subnet-ids subnet-aaa subnet-bbb --query 'Subnets[*].AvailabilityZone'` — must return ≥2 different values. Pick two from different AZs and re-deploy. |
| 3 | Target group is unhealthy after stack completes | Tool not actually reachable from NLB subnets, or wrong port | From an EC2 instance in one of the NLB subnets: `curl -kv https://<TargetValue>:<ToolPort>/`. If that fails, the tool's SG doesn't allow inbound from the NLB subnets. Open it. |
| 4 | BugRaid stack stuck at `CREATE_IN_PROGRESS` for ≥5 min | Customer hasn't accepted the endpoint connection | Customer runs `aws ec2 accept-vpc-endpoint-connections` per their runbook Step 5. CloudFormation will then proceed. |
| 5 | BugRaid stack fails at `InterfaceEndpoint` with `InvalidService` | Wrong `ServiceName` parameter, or customer hasn't allowlisted BugRaid's account | Verify customer's `EndpointServicePermissions` resource exists and `AllowedPrincipals` includes our `:root` ARN. Have customer re-run their stack or `modify-vpc-endpoint-service-permissions`. |
| 6 | BugRaid stack fails at `InterfaceEndpoint` with `Unsupported region for service` | Customer didn't add BugRaid's region to `BugRaidConsumerRegions` (cross-region PrivateLink) | Customer adds `ap-southeast-1` (or wherever BugRaid runs) to the `SupportedRegions` of their endpoint service. They can update the stack parameter or run `aws ec2 modify-vpc-endpoint-service-configuration --add-supported-regions ap-southeast-1`. |
| 7 | `nslookup grafana.weworkindia.internal` from melt-fetcher Fargate task returns `NXDOMAIN` | Private Hosted Zone not attached to BugRaid's VPC, or BugRaid VPC has DNS-resolution disabled | `aws route53 list-hosted-zones-by-vpc --vpc-id <bugraid-vpc>` — confirm zone is listed. If not, manually `associate-vpc-with-hosted-zone`. Also confirm `aws ec2 describe-vpc-attribute --vpc-id <bugraid-vpc> --attribute enableDnsSupport` returns `true`. |
| 8 | `nslookup` resolves to the endpoint DNS but `curl` returns `connection timed out` | Customer's NLB target health-check failing, OR Security Group on customer side blocks NLB subnets | Customer runs `aws elbv2 describe-target-health --target-group-arn <tg-arn>`. If targets show `unhealthy`, fix the tool's SG to allow inbound from the NLB subnets. |
| 9 | `curl` connects but returns `SSL: CERTIFICATE_VERIFY_FAILED` | Tool's TLS cert doesn't cover the hostname we used in `ToolHostname` | Two options. (a) Use the hostname the customer's cert ACTUALLY covers — check with `openssl s_client -connect <tool-ip>:<port> -servername foo \| openssl x509 -noout -text \| grep -A1 'Subject Alternative'`. Re-deploy BugRaid stack with the correct hostname. (b) Ask customer to add a SAN to their cert. |
| 10 | `curl` works from one Fargate task but fails from another | Subnet that the failing task runs in is NOT one of the endpoint's subnets | Each Interface Endpoint creates ENIs in specified subnets only. If melt-fetcher runs in 3 subnets but the endpoint covers only 2, traffic from the 3rd subnet has no path. Either add the 3rd subnet to the endpoint stack, or constrain Fargate to the 2 endpoint subnets. |
| 11 | melt-fetcher CloudWatch shows the right hostname but `0 rows` returned | Network path is fine; the tool's authentication is failing | Look at the tool's own access log. Auth is the tool's responsibility — usually wrong/expired API token in the dev-api integration record. PrivateLink does not change auth behaviour. |
| 12 | Customer revokes the connection but BugRaid's endpoint stack still exists | Expected — deletion isn't auto-cascading | BugRaid runs `aws cloudformation delete-stack` on the BugRaid-side stack to clean up the orphaned endpoint + Private Hosted Zone. |
| 13 | Customer wants to update `TargetValue` (their tool moved to a new IP) | CloudFormation handles target-group registration swap | Customer runs `aws cloudformation update-stack` with the new `TargetValue`. NLB target group registers the new target and de-registers the old one in one transaction. ~30 sec of overlap; no client-visible blip if the old target is still healthy during the swap. |
| 14 | TLS works but melt-fetcher times out on long queries | NLB idle timeout (350 sec) is shorter than the tool's response time for big queries | Two options. (a) Reduce query window in the adapter (preferred — long fetches are usually wrong shape). (b) Customer modifies NLB idle timeout via `--load-balancer-attributes Key=idle_timeout.timeout_seconds,Value=600`. NLB max is 600 sec for TCP. |
| 15 | Cross-region PrivateLink: connection works but throughput is much lower than expected | Cross-region traffic is rate-limited by AWS at higher percentiles; also bills per GB | If sustained throughput >100 Mbps is needed, consider colocating BugRaid's consumer VPC in the customer's region (separate Fargate deployment). This is rare for telemetry; consult TAM. |
| 16 | Customer's stack fails immediately with `User is not authorized to perform: ec2:CreateVpcEndpointService` | Customer's IAM identity policy or SCP blocks endpoint service creation | Customer's security/cloud-platform team adds the action to the policy. The deploying IAM role needs: `ec2:CreateVpcEndpointService`, `ec2:DescribeVpcEndpointServiceConfigurations`, `ec2:ModifyVpcEndpointServicePermissions`, `elasticloadbalancing:CreateLoadBalancer`, `elasticloadbalancing:CreateTargetGroup`, `elasticloadbalancing:RegisterTargets`, `elasticloadbalancing:CreateListener`. |

## Useful AWS CLI commands

```
# Customer: list pending endpoint connections waiting for accept
aws ec2 describe-vpc-endpoint-connections \
  --filters Name=vpc-endpoint-state,Values=pendingAcceptance --region <region>

# Customer: list current allowed principals
aws ec2 describe-vpc-endpoint-service-permissions \
  --service-id <id> --region <region>

# BugRaid: confirm endpoint reachable
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids <id> \
  --query 'VpcEndpoints[0].[State,DnsEntries]' --region <region>

# BugRaid: confirm Private Hosted Zone is attached to our VPC
aws route53 list-hosted-zones-by-vpc \
  --vpc-id <bugraid-vpc-id> --vpc-region <region>

# Both sides: live tail of CloudTrail for PrivateLink events
aws logs tail /aws/cloudtrail --since 10m --filter-pattern \
  '{ ($.eventSource = "ec2.amazonaws.com") && ($.eventName = "*VpcEndpoint*") }'
```

## If you get stuck

Post in the shared customer Slack channel with:

1. Both stack names (customer-side + BugRaid-side).
2. Output of `describe-stacks` for both.
3. Output of `describe-vpc-endpoint-connections` from the customer side.
4. The exact `curl` / `nslookup` command + output from the failing host.

A BugRaid platform engineer will respond within the SLA in your contract (typically 4 business hours for non-P0).
