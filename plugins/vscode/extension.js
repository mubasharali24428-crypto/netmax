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
  const cmd = vscode.commands.registerCommand('netmax.showTrends', () => {
    const panel = vscode.window.createWebviewPanel(
      'netmaxTrends', 'NetMax Trends', vscode.ViewColumn.One,
      { enableScripts: false });
    const { rows, source } = loadRuns();
    panel.webview.html = trends.renderPage(rows, source);
  });
  context.subscriptions.push(cmd);
}

function deactivate() {}

module.exports = { activate, deactivate, loadRuns, appSupportDir };
