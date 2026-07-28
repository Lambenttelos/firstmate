# Place source credentials on the server

Type: `wayfinder:task`. Status: open. Blocked by: Confirm the employer position on credentials leaving the company machine; Build the fleet container image.

## Question

Which credentials are placed on the server, how are they stored so they survive a container rebuild without ending up baked into an image, and what hardening goes with them?

## Context

The split decided in ADR 0021 is that source-side credentials move and production deployment credentials do not.
Hardening that rides along regardless: key-only SSH, no password authentication, firewall restricted to the VPN interface, full-disk encryption on the server, and no secrets in image layers.

## Resolved when

`gh auth status` and a git push both succeed from inside the container, production deployment credentials are demonstrably absent, and the hardening items are each verified rather than intended.
