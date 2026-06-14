#!/usr/bin/env node
// Signed GET of the backend task-queue count. Ed25519 over the timestamp (empty
// body for GET). Usage: be-queue-count.js <status> [project-lane]
const crypto = require('crypto'), fs = require('fs'), https = require('https');
const KEY = process.env.TMUX_KEY || (process.env.HOME + '/.tmux-cli-worker/keys/private.pem');
const BASE = process.env.TMUX_CLI_API_URL || 'https://tmux.vojta.ai';
const status = process.argv[2] || 'new';
const project = process.argv[3] || process.env.TMUX_PROJECT || '';
const key = crypto.createPrivateKey(fs.readFileSync(KEY, 'utf8'));
const ts = Math.floor(Date.now() / 1000).toString();
const sig = crypto.sign(null, Buffer.from(ts, 'utf8'), key).toString('base64');
const url = new URL(BASE + '/api/v1/tasks');
url.searchParams.set('status', status);
url.searchParams.set('limit', '1');
if (project) url.searchParams.set('project', project);
const req = https.request(url, { method: 'GET', timeout: 8000, headers: {
  'X-Signature': sig, 'X-Timestamp': ts, 'X-Fingerprint': process.env.TMUX_FP || 'remote-worker-dispatcher',
}}, res => {
  let b = ''; res.on('data', c => b += c); res.on('end', () => {
    if (res.statusCode !== 200) { console.error('HTTP ' + res.statusCode + ': ' + b.slice(0, 300)); process.exit(2); }
    try { console.log(JSON.parse(b).total ?? 0); } catch (e) { console.error('parse: ' + e.message); process.exit(3); }
  });
});
req.on('error', e => { console.error('req: ' + e.message); process.exit(4); });
req.on('timeout', () => { req.destroy(); console.error('timeout'); process.exit(5); });
req.end();
