# Securing Your MCP Server with Shared Signals: IBM Verify + HashiCorp Vault + IBM Antenna

A 45-minute hands-on walkthrough that lands a working MCP server on your laptop where every tool call is authorized by IBM Verify policy (with step-up MFA where the policy demands it) and runs under a 5-minute PostgreSQL credential that HashiCorp Vault mints fresh per call. Plus a 17th chapter that adds the OpenID Shared Signals Framework: three consecutive MFA denials trigger a tenant-wide session revocation through a local IBM Antenna v26.03 transmitter + receiver pair. No AWS account required.

## Table of contents

1. Architecture
2. The identity chain
3. Prerequisites
4. Clone the repo
5. Configure IBM Verify
6. Configure HashiCorp Vault
7. Configure PostgreSQL
8. Start the MCP server
9. Run the agent
10. End-to-end smoke test
11. Swapping the LLM
12. Anatomy of an MCP call
13. [SSF architecture — what Shared Signals is and how the v26.03 split images fit](ssf-architecture.md)
14. [SSF setup — bootstrapping Antenna in one command](ssf-setup.md)
15. [SSF demo walkthrough — 3 denials, tenant-wide revocation, sign in again](ssf-demo-walkthrough.md)
16. [SSF troubleshooting — the "stream silently dead" mode and other gotchas](ssf-troubleshooting.md)
17. [SSF manual deployment — what every script does, step-by-step](ssf-manual-deployment.md)
18. Troubleshooting
19. Logging for an enterprise SIEM
