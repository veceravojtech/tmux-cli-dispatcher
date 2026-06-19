#!/usr/bin/env node
// Host-side fleet status reporter. For every project bound to THIS host it gathers
// the local worker state (session up? taskvisor consuming? current goal? lane NEW
// count?) and POSTs one signed heartbeat to /api/v1/dispatchers/heartbeat. The
// backend upserts it onto the matching ProjectBinding rows and returns each
// worker's desired state. Run once, or with --loop to report every STATUS_INTERVAL
// seconds. Same Ed25519 signing as registry.js / be-queue-count.js.
//
// Tolerant by design: if the heartbeat endpoint isn't deployed yet (404) it logs
// once and keeps looping — the host-side glue can ship before the web release.
const crypto = require('crypto'), fs = require('fs'), https = require('https'),
      os = require('os'), { execSync } = require('child_process');
const KEY = process.env.TMUX_KEY || (process.env.HOME + '/.tmux-cli-worker/keys/private.pem');
const BASE = process.env.TMUX_CLI_API_URL || 'https://tmux.vojta.ai';
const WORKER_HOME = process.env.WORKER_HOME || (process.env.HOME + '/.tmux-cli-worker');
const FP = process.env.TMUX_FP || require('./fingerprint').fingerprint();
const HN = os.hostname();
const INTERVAL = (parseInt(process.env.STATUS_INTERVAL || '20', 10)) * 1000;
// Host-level git deploy PUBLIC key, surfaced in the web deploy form so an operator can authorize a
// NEW private repo before deploying it to this host. Read once from TMUX_DEPLOY_PUBKEY or the
// conventional ~/.ssh/id_tmux_deploy.pub; null/absent is fine (the form shows a not-reported note).
const DEPLOY_PUBKEY = (() => {
  const p = process.env.TMUX_DEPLOY_PUBKEY || (process.env.HOME + '/.ssh/id_tmux_deploy.pub');
  try { const k = fs.readFileSync(p, 'utf8').trim(); return k || null; } catch { return null; }
})();
const key = crypto.createPrivateKey(fs.readFileSync(KEY, 'utf8'));
const log = (...a) => console.error(new Date().toISOString(), ...a);
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Signed request. The web HMAC firewall verifies Ed25519 over (timestamp + body);
// GET has an empty body, so it signs the timestamp alone (matches registry.js).
function signed(method, path, bodyObj) {
  return new Promise(resolve => {
    const body = bodyObj ? JSON.stringify(bodyObj) : '';
    const ts = Math.floor(Date.now() / 1000).toString();
    const sig = crypto.sign(null, Buffer.from(ts + body, 'utf8'), key).toString('base64');
    const headers = { 'X-Signature': sig, 'X-Timestamp': ts, 'X-Fingerprint': FP };
    if (body) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = Buffer.byteLength(body); }
    const req = https.request(new URL(BASE + path), { method, timeout: 30000, headers }, res => {
      let b = ''; res.on('data', c => b += c); res.on('end', () => resolve({ status: res.statusCode, body: b }));
    });
    req.on('error', e => resolve({ status: 0, body: String(e) }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, body: 'timeout' }); });
    if (body) req.write(body);
    req.end();
  });
}

function sh(cmd) { try { return execSync(cmd, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch { return ''; } }

function sessionFor(path) { // tmux session whose TMUX_CLI_PROJECT_PATH == path
  for (const s of sh("tmux list-sessions -F '#{session_name}'").split('\n').filter(Boolean)) {
    if (sh(`tmux show-environment -t ${s} TMUX_CLI_PROJECT_PATH`).replace(/^TMUX_CLI_PROJECT_PATH=/, '') === path) return s;
  }
  return '';
}
function goalWindowsOpen(sid) {
  return sid ? /^(execute|supervisor-|validator|investigator)/m.test(sh(`tmux list-windows -t ${sid} -F '#{window_name}'`)) : false;
}
function currentGoal(path) { // best-effort: id of the first goal with status: running
  try {
    for (const blk of fs.readFileSync(path + '/.tmux-cli/goals.yaml', 'utf8').split(/-\s*id:/).slice(1)) {
      if (/status:\s*running/.test(blk)) { const id = (blk.match(/^\s*(\S+)/) || [])[1]; return id ? 'goal ' + id : ''; }
    }
  } catch {}
  return '';
}
function paused(project) { return fs.existsSync(WORKER_HOME + '/PAUSED') || fs.existsSync(WORKER_HOME + '/PAUSED-' + project); }

async function laneNew(lane) {
  const r = await signed('GET', `/api/v1/tasks?status=new&limit=1&project=${encodeURIComponent(lane)}`);
  if (r.status !== 200) return 0;
  try { return JSON.parse(r.body).total ?? 0; } catch { return 0; }
}
async function bindings() {
  const r = await signed('GET', `/api/v1/project-bindings?hostname=${encodeURIComponent(HN)}`);
  if (r.status !== 200) { log('project-bindings HTTP', r.status); return []; }
  try { return JSON.parse(r.body).bindings || []; } catch { return []; }
}

async function reportOnce() {
  const bs = await bindings();
  if (!bs.length) return;
  const workers = [];
  for (const b of bs) {
    const sid = sessionFor(b.path);
    const consuming = fs.existsSync(b.path + '/.tmux-cli/taskvisor-active') || goalWindowsOpen(sid);
    const runtimeState = paused(b.projectName) ? 'paused' : consuming ? 'consuming' : sid ? 'idle' : 'down';
    workers.push({ project: b.projectName, runtimeState, activity: currentGoal(b.path), laneNew: await laneNew(b.projectName) });
  }
  const r = await signed('POST', '/api/v1/dispatchers/heartbeat', { hostname: HN, workers, deployKey: DEPLOY_PUBKEY });
  if (r.status === 404) log('heartbeat 404 — web fleet API not deployed yet (workers:', workers.length + ')');
  else if (r.status !== 200) log('heartbeat HTTP', r.status, r.body.slice(0, 200));
}

(async () => {
  const loop = process.argv.includes('--loop');
  do {
    try { await reportOnce(); } catch (e) { log('report error', String(e)); }
    if (loop) await sleep(INTERVAL);
  } while (loop);
})();
