#!/usr/bin/env node
'use strict';

// fm-lavish-lan-relay.js - a raw-TCP passthrough relay in front of lavish-axi.
//
// lavish-axi's server binds 127.0.0.1 only and has no bind/host flag, so a phone
// that VPNs into the home network cannot reach it. This relay listens on a LAN
// address and forwards every byte, in both directions, to lavish's loopback port.
//
// It is a RAW TCP relay, not an HTTP proxy, on purpose: it never parses, rewrites,
// or terminates the stream, so HTTP, the WebSocket Upgrade handshake, and the live
// WebSocket frames lavish uses all pass through untouched. The session URL path is
// preserved as-is, so http://<lan-ip>:<port>/session/<id> maps straight onto
// lavish's own http://127.0.0.1:<target>/session/<id>.
//
// bin/fm-lavish-lan.sh owns the lifecycle (start, stop, status, idempotency, the
// LAN URL, and the reachability notice). This file owns only the byte forwarding.
// Configuration arrives entirely through environment variables so the manager can
// launch it detached with no argument parsing here:
//   FM_LL_BIND         listen address (default 0.0.0.0)
//   FM_LL_PORT         listen port (default 4388)
//   FM_LL_TARGET_HOST  upstream host (default 127.0.0.1)
//   FM_LL_TARGET_PORT  upstream port (default 4387)
//   FM_LL_PIDFILE      path this process writes its own pid to once listening,
//                      and unlinks on a clean shutdown; the manager treats the
//                      pidfile's appearance as the readiness signal.
//
// Exit status: 0 on a clean shutdown (SIGTERM/SIGINT), 3 when the listen port is
// already in use (EADDRINUSE), 1 on any other listen error.

const net = require('net');
const fs = require('fs');

const bindHost = process.env.FM_LL_BIND || '0.0.0.0';
const listenPort = parseInt(process.env.FM_LL_PORT || '4388', 10);
const targetHost = process.env.FM_LL_TARGET_HOST || '127.0.0.1';
const targetPort = parseInt(process.env.FM_LL_TARGET_PORT || '4387', 10);
const pidfile = process.env.FM_LL_PIDFILE || '';

const server = net.createServer((client) => {
  const upstream = net.connect(targetPort, targetHost);
  // A dead peer must not crash the relay: tear down the other half instead.
  client.on('error', () => upstream.destroy());
  upstream.on('error', () => client.destroy());
  // Raw bidirectional passthrough. pipe() propagates end/close in each direction,
  // so a half-close from either side is forwarded rather than swallowed.
  client.pipe(upstream);
  upstream.pipe(client);
});

server.on('error', (err) => {
  process.stderr.write('fm-lavish-lan-relay: ' + err.code + ' ' + err.message + '\n');
  process.exit(err.code === 'EADDRINUSE' ? 3 : 1);
});

server.listen(listenPort, bindHost, () => {
  if (pidfile) {
    try {
      fs.writeFileSync(pidfile, String(process.pid) + '\n');
    } catch (e) {
      process.stderr.write('fm-lavish-lan-relay: could not write pidfile ' + pidfile + ': ' + e.message + '\n');
      process.exit(1);
    }
  }
  process.stdout.write(
    'fm-lavish-lan-relay: listening ' + bindHost + ':' + listenPort +
    ' -> ' + targetHost + ':' + targetPort + '\n');
});

function shutdown() {
  try {
    server.close();
  } catch (e) { /* already closing */ }
  if (pidfile) {
    try {
      fs.unlinkSync(pidfile);
    } catch (e) { /* already gone */ }
  }
  process.exit(0);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
// The manager detaches this relay so it outlives the launching terminal. Ignore
// SIGHUP as a belt-and-suspenders so a closing SSH/VPN session cannot kill it.
process.on('SIGHUP', () => {});
