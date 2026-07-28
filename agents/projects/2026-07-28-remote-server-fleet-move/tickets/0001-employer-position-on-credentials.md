# Confirm the employer position on credentials leaving the company machine

Type: `wayfinder:task`. Status: open. Blocked by: none.

## Question

The captain has clearance for company code to run on the home server.
Does that clearance extend to company credentials living on that machine, specifically the GitHub, Bitbucket, npm, and harness credentials the fleet needs to work unattended?

## Why this blocks

This is not a design decision and cannot be resolved by reasoning about it.
If the answer is no, the credential split in ADR 0021 has to be redrawn before anything is placed on the server, and the away-mode autonomy the fleet relies on may not survive.

## Resolved when

The captain has an answer they are willing to act on, recorded here, and either the credential plan stands or a replacement plan is written.
