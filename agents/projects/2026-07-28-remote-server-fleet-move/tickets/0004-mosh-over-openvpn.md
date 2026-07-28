# Establish mosh access over OpenVPN

Type: `wayfinder:task`. Status: open. Blocked by: none.

## Question

Does mosh over the existing OpenVPN tunnel give a terminal that survives laptop sleep, network changes, and roaming, and what ports and firewall rules does it need?

## Context

The tunnel is not the pain point.
A long-lived interactive session over a tunnel that flaps is the pain point, and mosh is the layer that fixes exactly that.
This is also the independent second way in when the Paseo daemon is the thing that broke, so it must not depend on Paseo in any way.

## Resolved when

The captain can close the laptop, move to another network, reopen it, and find the same live session, with the firewall exposing mosh only on the VPN interface.
