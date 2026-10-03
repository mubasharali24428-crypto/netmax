'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const trends = require('../media/trends');

const JSONL = [
  '{"ts": 1729500000, "mode": "baseline", "resultRaw": "single-stream   1 stream(s)      9.4 Mbps   (9 MB in 8s)"}',
  '{"ts": 1729501800, "mode": "turbo", "resultRaw": "{\\"mbps\\": 42.5}"}',
  '{"ts": "2024-10-21T09:40:00Z", "mode": "dns", "resultRaw": "no mbps here"}',
  '<<corrupt line>>',
  '',
  '{"mode": "wifi"}',
].join('\n');

describe('parseSwiftJsonl', () => {
  it('parses epoch, ISO, JSON-mbps and prose-mbps; skips the rest', () => {
    const rows = trends.parseSwiftJsonl(JSONL);
    assert.equal(rows.length, 3);
    assert.equal(rows[0].t, 1729500000 * 1000);
    assert.equal(rows[0].mode, 'baseline');
    assert.equal(rows[0].mbps, 9.4);
    assert.equal(rows[1].mbps, 42.5);
    assert.equal(rows[2].mbps, null);
  });

  it('returns oldest-first regardless of input order', () => {
    const rows = trends.parseSwiftJsonl([
      '{"ts": 200, "mode": "b", "resultRaw": "1 Mbps"}',
      '{"ts": 100, "mode": "a", "resultRaw": "2 Mbps"}',
    ].join('\n'));
    assert.deepEqual(rows.map((r) => r.mode), ['a', 'b']);
  });
});

describe('extractMbps', () => {
  it('prefers JSON mbps over prose', () => {
    assert.equal(trends.extractMbps('{"mbps": 7.5} x 99 Mbps'), 7.5);
  });

  it('returns null when nothing parses', () => {
    assert.equal(trends.extractMbps('all good, no numbers'), null);
    assert.equal(trends.extractMbps(null), null);
  });
});

describe('svgChart', () => {
  it('renders one dot per Mbps reading', () => {
    const svg = trends.svgChart([
      { t: 1000, mode: 'a', mbps: 10 },
      { t: 2000, mode: 'b', mbps: 20 },
      { t: 3000, mode: 'c', mbps: null },
    ]);
    assert.match(svg, /<svg /);
    assert.equal((svg.match(/<circle /g) || []).length, 2);
  });

  it('placeholder when no readings', () => {
    assert.match(trends.svgChart([]), /No Mbps readings yet/);
    assert.match(trends.svgChart([{ t: 1, mode: 'x', mbps: null }]), /No Mbps readings yet/);
  });

  it('escapes hostile mode strings', () => {
    const svg = trends.svgChart([{ t: 1000, mode: '<img src=x>', mbps: 5 }]);
    assert.ok(!svg.includes('<img src=x>'));
    assert.ok(svg.includes('&lt;img'));
  });
});

describe('renderPage', () => {
  it('names source and lists latest runs', () => {
    const html = trends.renderPage(
      [{ t: 1000, mode: 'baseline', mbps: 9.4 }], 'history.db (1 rows)');
    assert.ok(html.includes('NetMax Trends'));
    assert.ok(html.includes('history.db (1 rows)'));
    assert.ok(html.includes('9.4 Mbps'));
  });
});
