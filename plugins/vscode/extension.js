'use strict';

/**
 * NetMax Trends — VS Code command opening a static trends webview.
 * Zero dependencies: history comes from the macOS app's own files
 * (SQLite via the system sqlite3 CLI, else history.jsonl), charted by
 * media/trends.js into dependency-free SVG. v1 is read-only on purpose:
 * no engine spawning, no network, no settings.
 */

const vscode = require('vscode');
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const trends = require('./media/trends');

function appSupportDir() {
  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'NetMaxDesktop');
  }
  return path.join(os.homedir(), '.local', 'share', 'NetMaxDesktop');
}

/** Rows newest-last; source label names what was actually read. */
function loadRuns() {
  const dir = appSupportDir();
  const db = path.join(dir, 'history.db');
  if (fs.existsSync(db)) {
    try {
      const out = execFileSync(
        'sqlite3', ['-json', db,
          'SELECT ts, mode, result_raw FROM history ORDER BY ts ASC, id ASC;'],
        { timeout: 10000, maxBuffer: 32 * 1024 * 1024 });
      const parsed = JSON.parse(String(out));
      if (Array.isArray(parsed) && parsed.length > 0) {
        return {
          rows: parsed.map((r) => ({
            t: trends.toEpochMs(r.ts),
            mode: typeof r.mode === 'string' ? r.mode : 'unknown',
            mbps: trends.extractMbps(r.result_raw),
          })).filter((r) => r.t !== null),
          source: `history.db (${parsed.length} rows)`,
        };
      }
    } catch { /* fall through to JSONL */ }
  }
  const jsonl = path.join(dir, 'history.jsonl');
  if (fs.existsSync(jsonl)) {
    const rows = trends.parseSwiftJsonl(fs.readFileSync(jsonl, 'utf-8'));
    return { rows, source: 'history.jsonl' };
  }
  return { rows: [], source: 'no history found — run the NetMax app once' };
}

function activate(context) {
  const show = vscode.commands.registerCommand('netmax.showTrends', () => {
    const panel = vscode.window.createWebviewPanel(
      'netmaxTrends', 'NetMax Trends', vscode.ViewColumn.One,
      { enableScripts: false });
    const { rows, source } = loadRuns();
    panel.webview.html = trends.renderPage(rows, source);
  });
  const check = vscode.commands.registerCommand('netmax.runCheck', async () => {
    const cfg = vscode.workspace.getConfiguration('netmax');
    const root = cfg.get('engineRoot', '') || process.env.NETMAX_ROOT || '';
    const python = cfg.get('pythonPath', '') || process.env.NETMAX_PYTHON || '/usr/bin/python3';
    if (!root) {
      vscode.window.showErrorMessage(
        'NetMax: set netmax.engineRoot (folder holding netmax.py) or NETMAX_ROOT first.');
      return;
    }
    const script = require('path').join(root, 'netmax.py');
    const run = (args) => new Promise((resolve) => {
      require('child_process').execFile(
        python, [script, ...args], { timeout: 120000 },
        (error, stdout, stderr) => resolve({ error, stdout: String(stdout || ''), stderr: String(stderr || '') }));
    });
    const panel = vscode.window.createWebviewPanel(
      'netmaxCheck', 'NetMax Check Result', vscode.ViewColumn.One,
      { enableScripts: false });
    panel.webview.html = trends.renderPage([], 'measuring…');
    const base = await run(['baseline', '--seconds', '8']);
    if (base.error) {
      panel.webview.html = trends.renderPage([],
        'baseline failed: ' + (base.stderr || base.error.message || 'unknown').slice(0, 200));
      return;
    }
    const row = trends.rowFromEngineOutput(base.stdout, 'baseline');
    panel.webview.html = trends.renderPage([row], 'live run just now (not saved to history)');
  });
  context.subscriptions.push(show, check);
}

function deactivate() {}

module.exports = { activate, deactivate, loadRuns, appSupportDir };
