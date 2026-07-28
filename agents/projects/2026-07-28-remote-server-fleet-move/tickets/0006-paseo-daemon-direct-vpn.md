# Stand up the Paseo daemon with direct VPN access

Type: `wayfinder:task`. Status: open. Blocked by: Build the fleet container image.

## Question

How is the Paseo daemon configured on the server so that both laptop and phone connect directly over OpenVPN, with no third party in the path?

## Context

Paseo supports direct connections as well as relay pairing.
The daemon binds to a network address, `PASEO_PASSWORD` is required once it binds beyond localhost, and the phone app accepts a daemon added by address.
Password authentication authenticates but does not encrypt, so the VPN supplies that layer.
The relay stays available as break-glass for the case where the VPN will not come up at all.

## Resolved when

Firstmate runs under that daemon, the laptop reaches it by address, the phone reaches it by address, and the daemon listens only on the VPN interface.
