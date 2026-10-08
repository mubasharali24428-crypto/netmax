'use strict';

function toEpochMs(value) {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value > 1e12 ? value : value * 1000;
  }
  if (typeof value === 'string' && value) {
    const ms = Date.parse(value);
    return Number.isNaN(ms) ? null : ms;
  }
  return null;
}

function extractMbps(raw) {
  if (raw === null || raw === undefined) return null;
  const text = typeof raw === 'string' ? raw : JSON.stringify(raw);
  const candidates = [text];
  const brace = /\{[^{}]*"mbps"[^{}]*\}/.exec(text);
  if (brace) candidates.unshift(brace[0]);
  for (const chunk of candidates) {
    try {
      const parsed = JSON.parse(chunk);
      const direct = parsed && (parsed.mbps ?? parsed.Mbps ?? parsed.download_mbps);
      if (typeof direct === 'number' && Number.isFinite(direct)) return direct;
    } catch { }
  }
  const m = /([\d.]+)\s*Mbps/.exec(text);
  return m ? parseFloat(m[1]) : null;
}

function parseSwiftJsonlLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;
  let obj;
  try {
    obj = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (!obj || typeof obj !== 'object') return null;
  const t = toEpochMs(obj.ts ?? obj.timestamp ?? obj.time);
  if (t === null) return null;
  const mode = typeof obj.mode === 'string' ? obj.mode : 'unknown';
  return {
    t,
    mode,
    mbps: extractMbps(obj.resultRaw ?? obj.result_raw ?? obj.result ?? obj.raw),
  };
}

function parseSwiftJsonl(text) {
  const rows = [];
  for (const line of String(text || '').split('\n')) {
    const parsed = parseSwiftJsonlLine(line);
    if (parsed) rows.push(parsed);
  }
  return rows.sort((a, b) => a.t - b.t);
}

function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function svgChart(rows) {
  const pts = rows.filter((r) => typeof r.mbps === 'number');
  if (pts.length === 0) {
    return '<div class="empty">No Mbps readings yet — run a speed test first.</div>';
  }
  const W = 640, H = 220, P = 34;
  const t0 = pts[0].t, t1 = pts[pts.length - 1].t;
  const maxV = Math.max(...pts.map((p) => p.mbps), 1) * 1.15;
  const X = (t) => (t1 === t0 ? W / 2 : P + ((t - t0) / (t1 - t0)) * (W - 2 * P));
  const Y = (v) => H - P - (v / maxV) * (H - 2 * P);
  const line = pts.map((p) => `${X(p.t).toFixed(1)},${Y(p.mbps).toFixed(1)}`).join(' ');
  const dots = pts.map((p) =>
    `<circle cx="${X(p.t).toFixed(1)}" cy="${Y(p.mbps).toFixed(1)}" r="3.5" fill="#7C5A9B">` +
    `<title>${escapeHtml(p.mode)} — ${p.mbps} Mbps — ` +
    `${escapeHtml(new Date(p.t).toLocaleString())}</title></circle>`).join('');
  const lo = new Date(t0).toLocaleDateString();
  const hi = new Date(t1).toLocaleDateString();
  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Mbps trend chart">` +
    `<line x1="${P}" y1="${H - P}" x2="${W - P}" y2="${H - P}" stroke="#555"/>` +
    `<line x1="${P}" y1="${P}" x2="${P}" y2="${H - P}" stroke="#555"/>` +
    `<text x="${P}" y="${P - 8}" fill="#aaa" font-size="11">${maxV.toFixed(0)} Mbps max</text>` +
    `<text x="${P}" y="${H - 8}" fill="#aaa" font-size="11">${escapeHtml(lo)}</text>` +
    `<text x="${W - P}" y="${H - 8}" fill="#aaa" font-size="11" text-anchor="end">${escapeHtml(hi)}</text>` +
    `<polyline points="${line}" fill="none" stroke="#7C5A9B" stroke-width="2"/>` +
    dots + `</svg>`;
}

function renderPage(rows, sourceLabel) {
  const withMbps = rows.filter((r) => typeof r.mbps === 'number');
  const items = rows.slice(-30).reverse().map((r) =>
    `<li><b>${r.mbps === null ? '—' : r.mbps + ' Mbps'}</b> ` +
    `<span class="mode">${escapeHtml(r.mode)}</span> ` +
    `<span class="ts">${escapeHtml(new Date(r.t).toLocaleString())}</span></li>`
  ).join('\n');
  return `<!DOCTYPE html><html><head><meta charset="utf-8">` +
    `<style>body{font-family:system-ui;background:#1F2635;color:#eee;padding:16px}` +
    `h1{font-size:16px}.empty{color:#888}.mode{color:#9ab}.ts{color:#777}` +
    `ul{list-style:none;padding:0}li{padding:3px 0;border-bottom:1px solid #333}` +
    `.src{color:#777;font-size:12px}</style></head><body>` +
    `<h1>NetMax Trends (${rows.length} runs, ${withMbps.length} with Mbps)</h1>` +
    `<p class="src">Source: ${escapeHtml(sourceLabel)}</p>` +
    svgChart(rows) +
    `<h2 style="font-size:13px">Latest runs</h2><ul>${items || '<li>none yet</li>'}</ul>` +
    `</body></html>`;
}

function rowFromEngineOutput(text, mode) {
  return { t: Date.now(), mode, mbps: extractMbps(text) };
}

module.exports = { toEpochMs, extractMbps, parseSwiftJsonlLine, parseSwiftJsonl, escapeHtml, svgChart, renderPage, rowFromEngineOutput };
