'use strict';
const vscode = require('vscode'), cp = require('child_process'), fs = require('fs'), os = require('os'), path = require('path'), readline = require('readline'), trends = require('./media/trends');
const appSupportDir = () => process.env.NETMAX_TEST_APP_SUPPORT_DIR || path.join(os.homedir(), process.platform==='darwin' ? 'Library/Application Support' : '.local/share', 'NetMaxDesktop');
const sqliteQuery = (db) => new Promise((res, rej) => cp.execFile('sqlite3', ['-json', db, 'SELECT ts, mode, substr(result_raw,1,4096) as result_raw FROM history ORDER BY ts DESC LIMIT 3001'], {timeout:3000, maxBuffer:16*1024*1024}, (e, stdout) => e ? rej(e) : res(String(stdout))));
const parseJsonlAsync = (filepath) => new Promise((resolve) => {
  let bytesRead = 0, limitReached = false, rows = [];
  const stream = fs.createReadStream(filepath, { highWaterMark: 64*1024 });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  stream.on('data', (c) => { if ((bytesRead += c.length) > 10*1024*1024) { limitReached = true; rl.close(); stream.destroy(); } });
  rl.on('line', (line) => {
    if (line.length > 64*1024) return;
    const p = trends.parseSwiftJsonlLine(line);
    if (p && rows.push(p) > 3001) rows.shift();
  });
  rl.on('close', () => resolve({ rows: rows.sort((a,b)=>b.t-a.t).slice(0, 3000).sort((a,b)=>a.t-b.t), limitReached: limitReached || rows.length>3000 }));
});
async function loadRuns() {
  const dir = appSupportDir(), db = path.join(dir, 'history.db'), jsonl = path.join(dir, 'history.jsonl');
  if (fs.existsSync(db)) {
    try {
      let parsed = JSON.parse(await sqliteQuery(db));
      if (Array.isArray(parsed) && parsed.length > 0) {
        const lim = parsed.length > 3000;
        return {
          rows: parsed.slice(0,3000).reverse().map((r) => ({ t: trends.toEpochMs(r.ts), mode: r.mode||'unknown', mbps: trends.extractMbps(r.result_raw) })).filter(r => r.t !== null),
          source: `history.db (${parsed.length} rows)${lim ? ' — limit reached, open NetMax app for full history' : ''}`
        };
      }
    } catch {}
  }
  if (fs.existsSync(jsonl)) {
    const { rows, limitReached } = await parseJsonlAsync(jsonl);
    return { rows, source: `history.jsonl${limitReached ? ' — limit reached, open NetMax app for full history' : ''}` };
  }
  return { rows: [], source: 'no history found — run the NetMax app once' };
}
function activate(ctx) {
  ctx.subscriptions.push(vscode.commands.registerCommand('netmax.showTrends', async () => {
    const panel = vscode.window.createWebviewPanel('netmaxTrends', 'NetMax Trends', vscode.ViewColumn.One, { enableScripts: false });
    const { rows, source } = await loadRuns();
    panel.webview.html = trends.renderPage(rows, source);
  }));
  ctx.subscriptions.push(vscode.commands.registerCommand('netmax.runCheck', async () => {
    const cfg = vscode.workspace.getConfiguration('netmax'), root = cfg.get('engineRoot') || process.env.NETMAX_ROOT, py = cfg.get('pythonPath') || process.env.NETMAX_PYTHON || '/usr/bin/python3';
    if (!root) return vscode.window.showErrorMessage('NetMax: set netmax.engineRoot (folder holding netmax.py) or NETMAX_ROOT first.');
    const script = path.join(root, 'netmax.py');
    const run = (args) => new Promise((res) => cp.execFile(py, [script, ...args], { timeout: 120000 }, (e, stdout, stderr) => res({ error: e, stdout: String(stdout||''), stderr: String(stderr||'') })));
    const panel = vscode.window.createWebviewPanel('netmaxCheck', 'NetMax Check Result', vscode.ViewColumn.One, { enableScripts: false });
    panel.webview.html = trends.renderPage([], 'measuring…');
    const base = await run(['baseline', '--seconds', '8']);
    if (base.error) return panel.webview.html = trends.renderPage([], 'baseline failed: ' + (base.stderr || base.error.message || 'unknown').slice(0, 200));
    panel.webview.html = trends.renderPage([trends.rowFromEngineOutput(base.stdout, 'baseline')], 'live run just now (not saved to history)');
  }));
}
module.exports = { activate, deactivate: ()=>{}, loadRuns, appSupportDir };
