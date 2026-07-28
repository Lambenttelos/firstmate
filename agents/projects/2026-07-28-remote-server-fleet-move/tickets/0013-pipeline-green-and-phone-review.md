# Prove one full pipeline run green on the server and review it from the phone

Type: `wayfinder:task`. Status: open. Blocked by: Move firstmate itself and the first clones.

## Question

Does a complete delivery run work end to end from the server, including the captain reviewing its result from the phone?

## Why this shape

This is the stage two gate, and it deliberately tests the whole chain rather than its parts.
A validation pipeline that goes green but cannot open a pull request, or a pull request the captain cannot reach from the phone, is a failed migration that looks like a working one.

## Resolved when

One full validation run passes on the server, a pull request opens, and the captain reads and acts on it from the phone over the VPN.
