#!/usr/bin/env node
// Host-side near-instant control listener. Holds a long-poll open to
// /api/v1/dispatchers/commands for THIS host; the moment an admin changes a
// worker's desiredState (controlVersion bumps) the request returns and we enact
// it locally — no waiting for the per-minute cron:
//   paused  -> touch  $WORKER_HOME/PAUSED-<project>   (dispatcher stops consuming, session kept warm)
//   running -> remove $WORKER_HOME/PAUSED-<project>   (dispatcher resumes)
//   stopped -> touch the flag AND kill the project's tmux session
// Reconciles current desired state on start (since=-1 returns immediately).
// Same Ed25519 signing as registry.js. Tolerant: if the endpoint isn't deployed
// yet (404) it backs off and retries rather than busy-looping.
const crypto = require('crypto'), fs = require('fs'), https = require('https'),
      os = require('os'), { execSync } = require('child_process');
const KEY = process.env.TMUX_KEY || (process.env.HOME + '/.tmux-cli-worker/keys/private.pem');
const BASE = process.env.TMUX_CLI_API_URL || 'https://tmux.vojta.ai';
const WORKER_HOME = process.env.WORKER_HOME || (process.env.HOME + '/.tmux-cli-worker');
const FP = process.env.TMUX_FP || 'remote-worker-dispatcher';
const HN = os.hostname();
const key = crypto.createPrivateKey(fs.readFileSync(KEY, 'utf8'));
const log = (...a) => console.error(new Date().toISOString(), ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

function signedGet(path) { // Ed25519 over (timestamp + '') for an empty-body GET
  return new Promise(resolve => {
    const ts = Math.floor(Date.now() / 1000).toString();
    const sig = crypto.sign(null, Buffer.from(ts, 'utf8'), key).toString('base64');
    const req = https.request(new URL(BASE + path), { method: 'GET', timeout: 40000,
      headers: { 'X-Signature': sig, 'X-Timestamp': ts, 'X-Fingerprint': FP } }, res => {
      let b = ''; res.on('data', c => b += c); res.on('end', () => resolve({ status: res.statusCode, body: b }));
    });
    req.on('error', e => resolve({ status: 0, body: String(e) }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: 'timeout' }); });
    req.end();
  });
}
function sh(cmd) { try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; } }
function sessionFor(path) {
  for (const s of sh("tmux list-sessions -F '#{session_name}'").split('\n').filter(Boolean)) {
    if (sh(`tmux show-environment -t ${s} TMUX_CLI_PROJECT_PATH`).replace(/^TMUX_CLI_PROJECT_PATH=/, '') === path) return s;
  }
  return '';
}
const flag = project => WORKER_HOME + '/PAUSED-' + project;

let pathByProject = {};
async function refreshBindings() {
  const r = await signedGet(`/api/v1/project-bindings?hostname=${encodeURIComponent(HN)}`);
  if (r.status === 200) { try { const m = {}; for (const b of (JSON.parse(r.body).bindings || [])) m[b.projectName] = b.path; pathByProject = m; } catch {} }
}

function enact(project, desiredState) {
  if (desiredState === 'running') {
    try { fs.rmSync(flag(project), { force: true }); } catch {}
    log(`[${project}] running -> cleared pause`);
  } else if (desiredState === 'paused') {
    try { fs.writeFileSync(flag(project), ''); } catch {}
    log(`[${project}] paused -> ${flag(project)}`);
  } else if (desiredState === 'stopped') {
    try { fs.writeFileSync(flag(project), ''); } catch {}
    const path = pathByProject[project];
    const s = path ? sessionFor(path) : '';
    if (s) { sh(`tmux kill-session -t ${s}`); log(`[${project}] stopped -> paused + killed session ${s}`); }
    else log(`[${project}] stopped -> paused (no live session)`);
  } else {
    log(`[${project}] unknown desiredState '${desiredState}' — ignored`);
  }
}

(async () => {
  await refreshBindings();
  let since = -1;        // -1 => first poll returns immediately, reconciling current state
  const applied = {};    // project -> last enacted controlVersion (avoid redundant enacts)
  let cycles = 0;
  for (;;) {
    const r = await signedGet(`/api/v1/dispatchers/commands?hostname=${encodeURIComponent(HN)}&since=${since}`);
    if (r.status === 404) { log('commands 404 — web fleet API not deployed yet; retry in 30s'); await sleep(30000); continue; }
    if (r.status !== 200) { log('commands HTTP', r.status, r.body.slice(0, 150), '; retry in 15s'); await sleep(15000); continue; }
    let data; try { data = JSON.parse(r.body); } catch { await sleep(5000); continue; }
    for (const w of (data.workers || [])) {
      if (applied[w.project] !== w.controlVersion) { enact(w.project, w.desiredState); applied[w.project] = w.controlVersion; }
    }
    if (typeof data.version === 'number') since = data.version;
    if (++cycles % 20 === 0) await refreshBindings();   // keep project->path map fresh
    await sleep(500);                                    // small gap so immediate returns don't hammer
  }
})();
