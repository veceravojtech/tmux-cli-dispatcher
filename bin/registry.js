#!/usr/bin/env node
// Signed GET of the project-binding registry for a hostname. Prints one binding
// per line, TAB-separated: projectName <TAB> path <TAB> repository <TAB> branch
const crypto = require('crypto'), fs = require('fs'), https = require('https'), os = require('os');
const KEY = process.env.TMUX_KEY || (process.env.HOME + '/.tmux-cli-worker/keys/private.pem');
const BASE = process.env.TMUX_CLI_API_URL || 'https://tmux.vojta.ai';
const hostname = process.argv[2] || os.hostname();
const key = crypto.createPrivateKey(fs.readFileSync(KEY, 'utf8'));
const ts = Math.floor(Date.now() / 1000).toString();
const sig = crypto.sign(null, Buffer.from(ts, 'utf8'), key).toString('base64');
const url = new URL(BASE + '/api/v1/project-bindings');
url.searchParams.set('hostname', hostname);
const req = https.request(url, { method: 'GET', timeout: 8000, headers: {
  'X-Signature': sig, 'X-Timestamp': ts, 'X-Fingerprint': process.env.TMUX_FP || 'worker-up',
}}, res => {
  let b = ''; res.on('data', c => b += c); res.on('end', () => {
    if (res.statusCode !== 200) { console.error('HTTP ' + res.statusCode + ': ' + b.slice(0, 300)); process.exit(2); }
    try { for (const x of (JSON.parse(b).bindings || [])) console.log([x.projectName, x.path, x.repository, x.branch || ''].join('\t')); }
    catch (e) { console.error('parse: ' + e.message); process.exit(3); }
  });
});
req.on('error', e => { console.error('req: ' + e.message); process.exit(4); });
req.on('timeout', () => { req.destroy(); console.error('timeout'); process.exit(5); });
req.end();
