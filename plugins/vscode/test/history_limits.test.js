const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');

const Module = require('module');
const originalRequire = Module.prototype.require;
Module.prototype.require = function(moduleName) {
  if (moduleName === 'vscode') {
    return {
      commands: { registerCommand: () => {} },
      window: { createWebviewPanel: () => {}, showErrorMessage: () => {} },
      workspace: { getConfiguration: () => ({ get: () => {} }) },
      ViewColumn: { One: 1 }
    };
  }
  return originalRequire.apply(this, arguments);
};

const testDir = path.join(__dirname, 'test_data');
process.env.NETMAX_TEST_APP_SUPPORT_DIR = testDir;

const extension = require('../extension');
const loadRuns = extension.loadRuns;

test('history_limits limits jsonl to 10MB and 3000 rows', async (t) => {
    fs.mkdirSync(testDir, { recursive: true });
    const jsonlPath = path.join(testDir, 'history.jsonl');
    const dbPath = path.join(testDir, 'history.db');
    if (fs.existsSync(jsonlPath)) fs.unlinkSync(jsonlPath);
    if (fs.existsSync(dbPath)) fs.unlinkSync(dbPath);
    
    const stream = fs.createWriteStream(jsonlPath);
    for(let i=0; i<3005; i++) {
        stream.write(JSON.stringify({ts: Date.now() + i, mode: 'test', result: `{"mbps": ${i}}`}) + '\n');
    }
    stream.end();
    
    await new Promise(resolve => stream.on('finish', resolve));
    
    const result = await loadRuns();
    assert.strictEqual(result.rows.length, 3000);
    assert.ok(result.source.includes('limit reached'));
    assert.strictEqual(result.rows[0].mbps, 5); 
    assert.strictEqual(result.rows[2999].mbps, 3004);
    
    fs.unlinkSync(jsonlPath);
});

test('history_limits skips over-length lines', async (t) => {
    fs.mkdirSync(testDir, { recursive: true });
    const jsonlPath = path.join(testDir, 'history.jsonl');
    const dbPath = path.join(testDir, 'history.db');
    if (fs.existsSync(jsonlPath)) fs.unlinkSync(jsonlPath);
    if (fs.existsSync(dbPath)) fs.unlinkSync(dbPath);
    
    const giantStr = 'A'.repeat(70000);
    fs.writeFileSync(jsonlPath, 
        JSON.stringify({ts: Date.now() + 1, mode: 'test', result: '{"mbps": 1}'}) + '\n' +
        JSON.stringify({ts: Date.now() + 2, mode: 'test', result: `{"mbps": 2, "junk": "${giantStr}"}`}) + '\n' +
        JSON.stringify({ts: Date.now() + 3, mode: 'test', result: '{"mbps": 3}'}) + '\n'
    );
    
    const result = await loadRuns();
    assert.strictEqual(result.rows.length, 2);
    assert.strictEqual(result.rows[0].mbps, 1);
    assert.strictEqual(result.rows[1].mbps, 3);
    
    fs.unlinkSync(jsonlPath);
});

test('history_limits queries SQLite with limit and timeout', async (t) => {
    fs.mkdirSync(testDir, { recursive: true });
    const jsonlPath = path.join(testDir, 'history.jsonl');
    const dbPath = path.join(testDir, 'history.db');
    if (fs.existsSync(jsonlPath)) fs.unlinkSync(jsonlPath);
    if (fs.existsSync(dbPath)) fs.unlinkSync(dbPath);
    
    const cp = require('child_process');
    const originalExecFile = cp.execFile;
    
    cp.execFile = function(file, args, opts, cb) {
        assert.strictEqual(file, 'sqlite3');
        assert.ok(args.join(' ').includes('LIMIT 3001'));
        assert.strictEqual(opts.timeout, 3000);
        assert.strictEqual(opts.maxBuffer, 16 * 1024 * 1024);
        
        const rows = [];
        for(let i=3000; i>=0; i--) { 
            // Mocking SQLite returning descending order
            rows.push({ts: Date.now() + i, mode: 'sql', result_raw: `{"mbps": ${i}}`});
        }
        cb(null, JSON.stringify(rows));
    };
    
    fs.writeFileSync(dbPath, 'dummy sqlite file to trigger path');
    
    try {
        const result = await loadRuns();
        assert.strictEqual(result.rows.length, 3000); 
        assert.ok(result.source.includes('limit reached'));
        assert.strictEqual(result.rows[0].mbps, 1); 
        assert.strictEqual(result.rows[2999].mbps, 3000);
    } finally {
        cp.execFile = originalExecFile;
        fs.unlinkSync(dbPath);
    }
});
