process.env.NETMAX_NO_START = "1";
import assert from "node:assert/strict";
import { test } from "node:test";
import { EventEmitter } from "node:events";
import { parseFleetConfig, resolveFleetTarget, fleetRequest } from "./netmax-mcp-server.mjs";

function config(allowlist, tokens = "{}") {
  return {
    NETMAX_FLEET_ALLOWLIST: allowlist,
    NETMAX_FLEET_TOKENS: tokens,
  };
}

test("fleet config accepts bounded aliases with exact HTTPS origins", () => {
  const peers = parseFleetConfig(config(
    JSON.stringify({ desk: "https://desk.example:8443", mini: "https://mini.example:443/" }),
    JSON.stringify({ desk: "desk-token" }),
  ));
  assert.deepEqual([...peers.values()], [
    { alias: "desk", origin: "https://desk.example:8443", hostname: "desk.example", port: "8443", token: "desk-token" },
    { alias: "mini", origin: "https://mini.example", hostname: "mini.example", port: "443", token: "" },
  ]);
});

test("fleet config rejects duplicate JSON keys before normalization", () => {
  assert.throws(() => parseFleetConfig(config(
    '{"desk":"https://one.example","desk":"https://two.example"}',
  )), /duplicate key/);
  assert.throws(() => parseFleetConfig(config(
    '{"desk":"https://one.example"}',
    '{"desk":"first","desk":"second"}',
  )), /duplicate key/);
});

test("fleet config rejects malformed maps, aliases, and token references", () => {
  for (const allowlist of [
    "not-json", "[]", "null", '{"Bad Alias":"https://peer.example"}',
    '{"desk":12}', '{"desk":"https://peer.example"'.padEnd(16_385, " "),
  ]) {
    assert.throws(() => parseFleetConfig(config(allowlist)));
  }
  assert.throws(() => parseFleetConfig(config(
    '{"desk":"https://desk.example"}', '{"unknown":"token"}',
  )), /unknown alias/);
  assert.throws(() => parseFleetConfig(config(
    '{"desk":"https://desk.example"}', JSON.stringify({ desk: "bad\ntoken" }),
  )), /control/);
  assert.throws(() => parseFleetConfig(config(
    '{"desk":"https://desk.example"}', JSON.stringify({ desk: "x".repeat(4097) }),
  )), /oversized/);
});

test("fleet config accepts only HTTPS origins without URL extras", () => {
  for (const origin of [
    "http://peer.example", "https://user:pass@peer.example",
    "https://peer.example/path", "https://peer.example?region=west",
    "https://peer.example/#fragment", "https://peer.example:bad",
    " https://peer.example", "https://peer.example%2eattacker.test",
  ]) {
    assert.throws(() => parseFleetConfig(config(JSON.stringify({ desk: origin }))));
  }
  assert.throws(() => parseFleetConfig(config(
    JSON.stringify(Object.fromEntries(Array.from({ length: 33 }, (_, i) => [
      `peer${i}`, `https://peer${i}.example`,
    ]))),
  )), /32 peers/);
});

const peer = { hostname: "peer.example", port: "8443" };
const answer = (address, family) => ({ address, family });
const fake = (answers) => async () => answers;

test("fleet DNS rejects every special-use IPv4 and IPv6 range", async () => {
  for (const [addr, fam] of [
    ["0.0.0.0", 4], ["10.1.2.3", 4], ["100.64.0.1", 4], ["127.0.0.1", 4],
    ["169.254.169.254", 4], ["172.16.0.1", 4], ["172.31.255.255", 4], ["192.0.0.1", 4],
    ["192.0.2.1", 4], ["192.168.1.1", 4], ["198.18.0.1", 4], ["198.51.100.1", 4],
    ["203.0.113.1", 4], ["224.0.0.1", 4], ["255.255.255.255", 4],
    ["::", 6], ["::1", 6], ["::ffff:8.8.8.8", 6], ["64:ff9b::808:808", 6],
    ["2001:db8::1", 6], ["2002::1", 6], ["fc00::1", 6], ["fd12::1", 6],
    ["fe80::1", 6], ["ff02::1", 6],
  ]) {
    await assert.rejects(resolveFleetTarget(peer, fake([answer(addr, fam)])), /non-global/, addr);
  }
});

test("fleet DNS accepts global addresses and returns a pinned target", async () => {
  assert.deepEqual(await resolveFleetTarget(peer, fake([answer("8.8.8.8", 4)])),
    { address: "8.8.8.8", family: 4, hostname: "peer.example", port: 8443 });
  assert.deepEqual(await resolveFleetTarget(peer, fake([answer("2606:4700:4700::1111", 6), answer("1.1.1.1", 4)])),
    { address: "2606:4700:4700::1111", family: 6, hostname: "peer.example", port: 8443 });
});

test("fleet DNS fails closed on empty, malformed, and mixed answer sets", async () => {
  for (const bad of [[], null, [answer("not-an-ip", 4)], [answer("8.8.8.8", 6)], [{ family: 4 }]]) {
    await assert.rejects(resolveFleetTarget(peer, fake(bad)), /no addresses|malformed/);
  }
  await assert.rejects(resolveFleetTarget(peer, fake([answer("8.8.8.8", 4), answer("10.0.0.1", 4)])), /non-global/);
});

test("fleet DNS propagates lookup failure and requests all answers", async () => {
  await assert.rejects(resolveFleetTarget(peer, async () => { throw new Error("ENOTFOUND"); }), /ENOTFOUND/);
  let opts;
  await resolveFleetTarget(peer, async (_h, o) => { opts = o; return [answer("8.8.8.8", 4)]; });
  assert.equal(opts.all, true);
});

// ── B-07-HTTP: fake transport seam, no sockets ──
const pinned = async () => ({ address: "8.8.8.8", family: 4, hostname: "peer.example", port: 8443 });
function fakeTransport(script) {
  const seen = {};
  const transport = (opts, onRes) => {
    seen.opts = opts;
    const req = new EventEmitter();
    req.setTimeout = (ms, cb) => { seen.timeoutMs = ms; seen.onTimeout = cb; };
    req.destroy = () => { seen.destroyed = true; };
    req.end = () => script(req, onRes, seen);
    return req;
  };
  return { transport, seen };
}
const response = (status, chunks) => {
  const res = new EventEmitter();
  res.statusCode = status;
  res.destroy = () => { res.destroyed = true; };
  queueMicrotask(() => { for (const c of chunks) res.emit("data", Buffer.from(c)); res.emit("end"); });
  return res;
};
const tokenPeer = { alias: "desk", hostname: "peer.example", port: "8443", token: "desk-token" };

test("fleet HTTP pins the address, keeps TLS verification, and sends only that token", async () => {
  const { transport, seen } = fakeTransport((_r, onRes) => onRes(response(200, ["ok"])));
  const out = await fleetRequest(tokenPeer, { resolve: pinned, transport });
  assert.deepEqual(out, { status: 200, body: "ok" });
  assert.equal(seen.opts.host, "peer.example");
  assert.equal(seen.opts.servername, "peer.example");
  assert.equal(seen.opts.rejectUnauthorized, true);
  assert.deepEqual(seen.opts.headers, { authorization: "Bearer desk-token" });
  assert.equal(seen.opts.timeout, 5000);
  await new Promise((res) => seen.opts.lookup("peer.example", {}, (e, a, f) => { assert.deepEqual([e, a, f], [null, "8.8.8.8", 4]); res(); }));
});

test("fleet HTTP sends no authorization header for a tokenless peer", async () => {
  const { transport, seen } = fakeTransport((_r, onRes) => onRes(response(200, ["ok"])));
  await fleetRequest({ ...tokenPeer, token: "" }, { resolve: pinned, transport });
  assert.deepEqual(seen.opts.headers, {});
});

test("fleet HTTP refuses redirects, oversized bodies, timeouts, and bad DNS", async () => {
  let t = fakeTransport((_r, onRes) => onRes(response(302, [])));
  await assert.rejects(fleetRequest(tokenPeer, { resolve: pinned, transport: t.transport }), /redirect refused/);
  t = fakeTransport((_r, onRes) => onRes(response(200, ["x".repeat(16 * 1024), "y"])));
  await assert.rejects(fleetRequest(tokenPeer, { resolve: pinned, transport: t.transport }), /too large/);
  assert.equal(t.seen.destroyed, true);
  t = fakeTransport((_r, _o, seen) => queueMicrotask(() => seen.onTimeout()));
  await assert.rejects(fleetRequest(tokenPeer, { resolve: pinned, transport: t.transport }), /timed out/);
  let called = false;
  t = fakeTransport(() => { called = true; });
  await assert.rejects(fleetRequest(tokenPeer, { resolve: async () => { throw new Error("non-global"); }, transport: t.transport }), /non-global/);
  assert.equal(called, false);
});

test("exactly 16 KiB is accepted", async () => {
  const { transport } = fakeTransport((_r, onRes) => onRes(response(200, ["x".repeat(16 * 1024)])));
  assert.equal((await fleetRequest(tokenPeer, { resolve: pinned, transport })).body.length, 16 * 1024);
});

// ── B-07-CUTOVER: route-level behaviour through fleetStatus ──
test("fleet status returns one bounded entry per alias and ignores legacy vars", async () => {
  const { fleetStatus } = await import("./netmax-mcp-server.mjs");
  const calls = [];
  const { transport } = fakeTransport((_r, onRes) => onRes(response(200, ["a\nb\nc\nd\ne"])));
  const spy = (opts, cb) => { calls.push(opts.host); return transport(opts, cb); };
  const env = { NETMAX_FLEET_ALLOWLIST: '{"a":"https://a.example","b":"https://b.example"}',
    NETMAX_FLEET: "x=http://evil", NETMAX_FLEET_TOKEN: "legacy" };
  const out = JSON.parse(await fleetStatus(env, { resolve: pinned, transport: spy }));
  assert.deepEqual(out.peers.map((p) => [p.name, p.ok, p.status]), [["a", true, "a | b | c | d"], ["b", true, "a | b | c | d"]]);
  assert.deepEqual(calls.sort(), ["a.example", "b.example"].map(() => "peer.example"));
});

test("fleet status makes zero requests for invalid or legacy-only config", async () => {
  const { fleetStatus } = await import("./netmax-mcp-server.mjs");
  let called = 0;
  const deps = { resolve: async () => { called++; return pinned(); }, transport: () => { called++; } };
  const bad = JSON.parse(await fleetStatus({ NETMAX_FLEET_ALLOWLIST: '{"a":"http://a.example"}' }, deps));
  assert.deepEqual(bad.peers, []); assert.ok(bad.error);
  assert.deepEqual(JSON.parse(await fleetStatus({ NETMAX_FLEET: "a=https://a.example" }, deps)).peers, []);
  assert.equal(called, 0);
});

test("fleet status reports per-peer failures inline", async () => {
  const { fleetStatus } = await import("./netmax-mcp-server.mjs");
  const out = JSON.parse(await fleetStatus(
    { NETMAX_FLEET_ALLOWLIST: '{"a":"https://a.example"}' },
    { resolve: async () => { throw new Error("non-global"); } }));
  assert.equal(out.peers[0].ok, false);
  assert.match(out.peers[0].status, /non-global/);
});
