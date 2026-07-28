# Map: move the fleet home to the server

Label: `wayfinder:map`.
Charted: 2026-07-28, from the grilling session recorded in [ADR 0021](../../../docs/adr/0021-move-the-fleet-home-to-the-server.md).

## Destination

The entire firstmate home runs on the home server, the captain reaches it from laptop and phone over their own VPN, and the laptop holds no standing fleet of its own.
Reaching the destination means one unattended overnight session has run cleanly on the server and the cold local rebuild procedure is written down.

## Notes

Domain: firstmate fleet operations, unraid server administration, container and tunnel setup.

This map deliberately overrides the plan-only default.
The shape was settled during the grilling session and is recorded in ADR 0021, so what remains is largely a staged migration.
Tickets that still hold a real decision are marked as such in their own body.

Skills every session should consult: `firstmate-coding-guidelines` before touching shared tracked material, `project-management` before touching clones, `secondmate-provisioning` if a second home is ever seeded, and `/grilling` with `/domain-modeling` for any ticket that carries an open decision.

Standing preferences for this effort:

- No unlanded work migrates. Everything in flight lands or is pushed to origin before its stage runs.
- `data/` and `state/` are copied. `.treehouse/` pools and `node_modules` are rebuilt on the server, never moved.
- Stage gates are pass or fail, not opinions. A failed gate stops the stage rather than being argued past.

Prerequisite outside this map: `cap-vitest-concurrency` sizes vitest workers from available memory rather than core count, and it should land before six heavy slots run hot.

## Decisions so far

- [ADR 0021, move the whole fleet home to the server](../../../docs/adr/0021-move-the-fleet-home-to-the-server.md) - the whole home moves, not the workers alone. The earlier "do not move agents" rejection is upheld for the workers-only shape and does not apply to this one.
- Server unreachable is answered by a single home plus a cold rebuild, with no standing local fleet.
- Source credentials move to the server, production deployment credentials do not.
- Transport stays OpenVPN, with mosh above it for roaming. WireGuard is the named upgrade, Tailscale stays rejected.
- The fleet working set lives on the SSD cache pool, never the parity array and never inside the Docker vdisk.
- The whole home runs in one long-lived container, not one container per agent and not bare on the unraid host.
- Heavy runs execute directly in the fleet container for now. The remote-executor design returns later as a cross-host pool.
- The agent ceiling is 16 and the heavy-run slot count is 6.
- Firstmate is hosted by a Paseo daemon on the server, reached directly over the VPN by both laptop and phone, with mosh as the independent second way in.

## Not yet specified

- What triggers the move from OpenVPN to native WireGuard, expressed as an observation rather than a preference.
- What the second remote host in the eventual pool actually is, and where it lives.
- How Playwright sharding is configured per project once slots span hosts.
- How work is routed by hand between the server home and a future laptop home, given both have their own backlog.
- What health signal tells the captain the server is degrading before a worker notices.

## Out of scope

- Distributing the queue across several firstmates for the whole development team. This is the acknowledged eventual direction and it redraws the destination, so it returns as a fresh effort rather than a continuation.
- Using the Windows desktop as fleet capacity. Previously rejected, not revisited.
- Installing Tailscale on the company laptop. Rejected while OpenVPN with mosh holds.

## Tickets

Frontier is any open ticket whose blockers are all closed.

| Ticket | Type | Blocked by |
|---|---|---|
| [Confirm the employer position on credentials leaving the company machine](tickets/0001-employer-position-on-credentials.md) | task | none |
| [Lay out the fleet share on the SSD cache pool](tickets/0002-fleet-share-layout.md) | task | none |
| [Build the fleet container image](tickets/0003-fleet-container-image.md) | task | none |
| [Establish mosh access over OpenVPN](tickets/0004-mosh-over-openvpn.md) | task | none |
| [Decide the backup path for irreplaceable fleet records](tickets/0005-backup-path-for-fleet-records.md) | grilling | Lay out the fleet share on the SSD cache pool |
| [Stand up the Paseo daemon with direct VPN access](tickets/0006-paseo-daemon-direct-vpn.md) | task | Build the fleet container image |
| [Place source credentials on the server](tickets/0007-place-source-credentials.md) | task | Confirm the employer position on credentials leaving the company machine; Build the fleet container image |
| [Run one task end to end on the server while the fleet stays local](tickets/0008-first-task-end-to-end.md) | task | Lay out the fleet share on the SSD cache pool; Build the fleet container image; Establish mosh access over OpenVPN; Stand up the Paseo daemon with direct VPN access; Place source credentials on the server |
| [Migrate no-mistakes with its live state](tickets/0009-migrate-no-mistakes.md) | task | Run one task end to end on the server while the fleet stays local |
| [Move firstmate itself and the first clones](tickets/0010-move-firstmate-and-first-clones.md) | task | Run one task end to end on the server while the fleet stays local; Migrate no-mistakes with its live state |
| [Trim per-agent overhead for a headless fleet](tickets/0011-trim-per-agent-overhead.md) | task | Move firstmate itself and the first clones |
| [Determine whether the long session freeze follows to Linux](tickets/0012-does-the-freeze-follow.md) | research | Move firstmate itself and the first clones |
| [Prove one full pipeline run green on the server and review it from the phone](tickets/0013-pipeline-green-and-phone-review.md) | task | Move firstmate itself and the first clones |
| [Cut over the remaining clones, records, and scheduled work](tickets/0014-full-cutover.md) | task | Prove one full pipeline run green on the server and review it from the phone |
| [Write the cold local rebuild procedure](tickets/0015-cold-local-rebuild-procedure.md) | task | Cut over the remaining clones, records, and scheduled work |
| [Prove one unattended overnight run on the server](tickets/0016-unattended-overnight-run.md) | task | Cut over the remaining clones, records, and scheduled work |
| [Validate the sixteen agent and six slot numbers under real load](tickets/0017-validate-the-two-numbers.md) | task | Prove one unattended overnight run on the server |
| [Design the cross-host test-execution pool](tickets/0018-cross-host-test-pool.md) | grilling | Prove one unattended overnight run on the server |
| [Stand up the laptop as a second independent home](tickets/0019-laptop-second-home.md) | task | Design the cross-host test-execution pool |
