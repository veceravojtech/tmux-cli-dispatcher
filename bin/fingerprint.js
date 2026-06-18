// Computes THIS host's identity fingerprint byte-for-byte identically to the Go
// tmux-cli (internal/identity.Fingerprint), so the host glue asserts the same
// X-Fingerprint the backend allowlist (SEC-1) was populated with.
//
// Why this matters: the backend verifies every signed request against the single
// shared Ed25519 key, then authorizes the *self-asserted* X-Fingerprint against
// an admin-enabled TmuxInstance/ProjectBinding. The control-plane routes
// (/api/v1/dispatchers*) are allowlist-gated, so a placeholder fingerprint is
// rejected 403 — heartbeats silently fail and the fleet shows "down". The hosts
// must assert their REAL fingerprint (still signing with the shared key).
//
// Derivation MUST match internal/identity exactly:
//   sha256_hex( machineID | hostname | GOOS | GOARCH | username )
// machineID = trimmed /etc/machine-id, else /var/lib/dbus/machine-id, else
//   sha256_hex(hostname | username | homedir); GOOS/GOARCH are Go's runtime
//   strings (node platform/arch mapped); username = userInfo, else $USER, else
//   $LOGNAME. Verified to reproduce the allowlisted fingerprints on the fleet.
const crypto = require('crypto'), fs = require('fs'), os = require('os');

const hash = (s) => crypto.createHash('sha256').update(s).digest('hex');

function username() {
  try { const u = os.userInfo().username; if (u) return u; } catch { /* fall through */ }
  return process.env.USER || process.env.LOGNAME || '';
}

function homedir() {
  try { return os.homedir() || ''; } catch { return ''; }
}

function machineID() {
  for (const p of ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
    try { const id = fs.readFileSync(p, 'utf8').trim(); if (id) return id; } catch { /* next */ }
  }
  return hash(os.hostname() + '|' + username() + '|' + homedir());
}

// Map node's process.arch/platform onto Go's runtime.GOARCH/GOOS strings.
const GOARCH = { x64: 'amd64', arm64: 'arm64', ia32: '386', arm: 'arm' }[process.arch] || process.arch;
const GOOS = { linux: 'linux', darwin: 'darwin', win32: 'windows' }[process.platform] || process.platform;

function fingerprint() {
  return hash(machineID() + '|' + os.hostname() + '|' + GOOS + '|' + GOARCH + '|' + username());
}

module.exports = { fingerprint };

// `node fingerprint.js` prints the fingerprint — handy for install.sh / debugging.
if (require.main === module) process.stdout.write(fingerprint() + '\n');
