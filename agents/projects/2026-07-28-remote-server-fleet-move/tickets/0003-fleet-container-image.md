# Build the fleet container image

Type: `wayfinder:task`. Status: open. Blocked by: none.

## Question

What goes into the single long-lived container that holds the whole fleet home, and how is it rebuilt from scratch?

## Context

The unraid host root filesystem is rebuilt from flash on each boot, which is why the fleet lives in a container rather than bare on the host.
The image needs git, tmux, mosh, node at the versions the projects pin, the harness CLIs, Playwright's browser dependencies, and the toolchain firstmate's bootstrap detects.
`FM_HOME`, `projects/`, and `.treehouse/` are bind mounts, so the image itself stays disposable.

## Resolved when

A Dockerfile is committed, the container starts and survives a server reboot, and `bin/fm-bootstrap.sh` inside it reports no missing tooling.
