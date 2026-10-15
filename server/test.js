// Server tests that run anywhere Node does (no macOS binary, no network, no
// real keys): node test.js. A throwaway Ed25519 key signs everything and
// Stripe is a local fake. Covers review findings 6, 7, 10, 11 and 14, the
// patch review's N1, N3 (rebind), N7 and N8, v2's R1 and R2, and v4's H1,
// M1, L1 and L2. Every license belongs to an install secret; there is no
// lookup by install id.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, verify } from "node:crypto";
import { createServer } from "node:http";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Stripe from "stripe";
import {
  checkoutSessionObject,
  eventObject,
  fixture,
  fixtureApiVersion,
  fixtureNames,
  invoiceObject,
  invoicePaymentsList,
  refundObject,
  subscriptionObject,
} from "./fixtures/stripe.js";

const work = mkdtempSync(join(tmpdir(), "nstest-"));
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const keyPath = join(work, "throwaway.pem");
writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
process.env.NIGHTSHIFT_LICENSE_KEY = keyPath;
process.env.NIGHTSHIFT_LICENSE_STORE = join(work, "licenses.json");
process.env.STRIPE_WEBHOOK_SECRET = "whsec_nightshift_test";
process.env.STRIPE_PRICE_ID = "price_test";
delete process.env.STRIPE_SECRET_KEY;
delete process.env.STRIPE_PORTAL_LOGIN_URL;

const app = await import("./app.js");
const {
  listen,
  signRamp,
  signTime,
  tokenPayload,
  saveLicense,
  licenseFor,
  stripeApiVersion,
  timeFloor,
  timeCeiling,
  useClockForTests,
} = app;

const A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const D = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const unix = (y, m, d) => Math.floor(Date.UTC(y, m - 1, d) / 1000);
const sha = (text) => createHash("sha256").update(text).digest("hex");
// Each test install's own secret, as its Mac would hold it.
const secretFor = (installId) => sha(`secret:${installId}`);
let passed = 0;

function check(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => {
      passed++;
    })
    .catch((error) => {
      console.error(`fail ${name}`);
      throw error;
    });
}

function verifies(token, payload) {
  const dot = token.indexOf(".");
  const body = Buffer.from(token.slice(0, dot), "base64");
  const sig = Buffer.from(token.slice(dot + 1), "base64");
  return body.toString() === payload && verify(null, body, publicKey, sig);
}

// A fake of the Stripe calls the server makes. v8: its objects are built
// from responses captured in a sandbox at the pinned API version
// (fixtures/stripe.js), so an invoice carries no payment fields.
const hooks = new Stripe("sk_test_local", { apiVersion: stripeApiVersion }).webhooks;
const subscriptions = {};
const unreachable = new Set();
const created = [];
// Every cancel or refund the server asks for, with its idempotency key, and
// what Stripe would have done: a repeated key repeats nothing.
const billingChanges = [];
const billingDone = new Map();
const failingRefunds = new Set();
// What Stripe has done, which outlives its 24-hour idempotency keys.
const canceledSubs = new Set();
const refundedPayments = new Set();
function billingCall(kind, target, options) {
  const key = options?.idempotencyKey;
  billingChanges.push([kind, target, key]);
  if (key && billingDone.has(key)) {
    return { id: `${kind}_${target}` };
  }
  if (kind === "cancel" && canceledSubs.has(target)) {
    throw Object.assign(
      new Error("A canceled subscription can only update its cancellation_details and metadata."),
      { type: "StripeInvalidRequestError" },
    );
  }
  if (kind === "refund" && refundedPayments.has(target)) {
    throw Object.assign(new Error(`Charge ${target} has already been refunded.`), {
      type: "StripeInvalidRequestError",
      code: "charge_already_refunded",
    });
  }
  if (kind === "cancel") {
    canceledSubs.add(target);
    if (subscriptions[target]) {
      subscriptions[target].status = "canceled";
    }
  }
  if (kind === "refund") {
    refundedPayments.add(target);
  }
  billingDone.set(key || `${kind}:${billingChanges.length}`, [kind, target]);
  return { id: `${kind}_${target}` };
}
const effects = (kind) => [...billingDone.values()].filter(([done]) => done === kind);
// Every checkout or portal session the server asks Stripe for.
const stripeCalls = [];
// Checkout sessions /success can look up, by id.
const checkoutSessions = {};
const fake = {
  webhooks: hooks,
  subscriptions: {
    retrieve: async (id) => {
      if (unreachable.has(id)) {
        throw Object.assign(new Error("connection reset secret-detail"), {
          type: "StripeConnectionError",
        });
      }
      if (!subscriptions[id]) {
        // What Stripe answers for a subscription it doesn't have.
        throw Object.assign(new Error(`No such subscription: '${id}' secret-detail`), {
          type: "StripeInvalidRequestError",
          code: "resource_missing",
        });
      }
      return subscriptionObject(id, {
        latest_invoice: invoiceOfSubscription(id),
        ...subscriptions[id],
      });
    },
    cancel: async (id, params, options) => billingCall("cancel", id, options),
    update: async (id, params, options) => billingCall("update", id, options),
    del: async (id, params, options) => billingCall("del", id, options),
  },
  refunds: {
    create: async (params, options) => {
      const target = params.payment_intent || params.charge;
      if (failingRefunds.has(target)) {
        throw Object.assign(new Error("refund declined secret-detail"), {
          type: "StripeInvalidRequestError",
        });
      }
      billingCall("refund", target, options);
      return refundObject(`re_${target}`, params);
    },
  },
  invoices: {
    // Payments only when expanded, as Stripe does at the pinned version.
    retrieve: async (id, params = {}) => {
      invoiceCalls.push(["retrieve", id, params.expand || []]);
      const owner = invoiceOwner(id);
      const expanded = (params.expand || []).includes("payments");
      return invoiceObject(id, {
        ...owner,
        payments: expanded
          ? invoicePaymentsList(id, listOnlyInvoices.has(id) ? null : `pi_${id}`)
          : undefined,
      });
    },
  },
  invoicePayments: {
    list: async ({ invoice }) => {
      invoiceCalls.push(["list", invoice]);
      return invoicePaymentsList(invoice, `pi_${invoice}`);
    },
  },
  checkout: {
    sessions: {
      create: async (params) => {
        stripeCalls.push(["checkout", params]);
        created.push(params);
        return checkoutSessionObject(`cs_created_${created.length}`, {
          status: "open",
          payment_status: "unpaid",
          url: "https://checkout.stripe.com/c/pay/test",
        });
      },
      list: async ({ subscription }) => ({
        ...fixture("checkout-sessions-list-by-subscription"),
        data: Object.entries(checkoutSessions)
          .filter(([, session]) => session.subscription === subscription)
          .map(([id, session]) => checkoutSessionObject(id, session)),
      }),
      retrieve: async (id) => {
        if (checkoutSessions[id]) {
          return checkoutSessionObject(id, checkoutSessions[id]);
        }
        throw Object.assign(new Error(`No such checkout.session: '${id}' secret-detail`), {
          type: "StripeInvalidRequestError",
        });
      },
    },
  },
  billingPortal: {
    sessions: {
      create: async ({ customer }) => {
        stripeCalls.push(["portal", customer]);
        return { url: `https://billing.stripe.com/p/session/${customer}` };
      },
    },
  },
};

// Which subscription each invoice bills: the checkout session that made
// it, unless a test says otherwise.
const invoiceOwners = {};
// Each subscription's latest invoice, as paid() issues them.
const latestInvoices = {};
const listOnlyInvoices = new Set();
const invoiceCalls = [];
function invoiceOwner(id) {
  const sessionFor = Object.values(checkoutSessions).find((session) => session.invoice === id);
  const subscription = invoiceOwners[id] || sessionFor?.subscription || null;
  return {
    subscription,
    customer: sessionFor?.customer || null,
    metadata: subscriptions[subscription]?.metadata || {},
  };
}
function invoiceOfSubscription(subscription) {
  return (
    latestInvoices[subscription] ||
    Object.values(checkoutSessions).find((session) => session.subscription === subscription)
      ?.invoice ||
    null
  );
}

const server = listen(0, fake);
await new Promise((resolve) => server.on("listening", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

let eventCount = 0;
async function webhook(event, expected = 200) {
  const payload = JSON.stringify({ object: "event", ...event });
  const header = hooks.generateTestHeaderString({
    payload,
    secret: process.env.STRIPE_WEBHOOK_SECRET,
  });
  const response = await fetch(`${base}/webhook`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Stripe-Signature": header },
    body: payload,
  });
  assert.equal(response.status, expected, await response.text());
}

function paid(installId, subscription, end, id = `evt_${++eventCount}`) {
  if (subscription) {
    invoiceOwners[`in_${id}`] = subscription;
    latestInvoices[subscription] = `in_${id}`;
  }
  return eventObject(
    id,
    "invoice.paid",
    invoiceObject(`in_${id}`, {
      subscription,
      customer: `cus_${installId.slice(0, 4)}`,
      end,
      metadata: {
        install_id: installId,
        // What checkout stored: the buying Mac's secret's hash.
        secret_hash:
          subscriptions[subscription]?.metadata?.secret_hash || sha(secretFor(installId)),
      },
    }),
  );
}

function deleted(installId, subscription, id = `evt_${++eventCount}`) {
  return eventObject(
    id,
    "customer.subscription.deleted",
    subscriptionObject(subscription, { status: "canceled", metadata: { install_id: installId } }),
  );
}

// A license fetch as the Mac makes it: POST with its secret (null: none).
async function license(installId, headerSecret = secretFor(installId)) {
  const headers = { "Content-Type": "application/json" };
  if (headerSecret) {
    headers["X-Nightshift-Secret"] = headerSecret;
  }
  const response = await fetch(`${base}/license`, {
    method: "POST",
    headers,
    body: JSON.stringify({ install_id: installId }),
  });
  return {
    status: response.status,
    body: response.status === 200 || response.status === 409 ? await response.json() : null,
    time: response.headers.get("x-nightshift-time"),
  };
}

// Finding 6: bound, unique, dated tokens.
await check("tokens are bound to the install", () => {
  const a = signRamp(A, "2027-10-01");
  const b = signRamp(B, "2027-10-01");
  assert.notEqual(a, b);
  assert.ok(verifies(a, `ramp:${A}:2027-10-01`));
  assert.ok(verifies(b, `ramp:${B}:2027-10-01`));
  assert.equal(tokenPayload(a), `ramp:${A}:2027-10-01`);
  assert.equal(signRamp(A.toUpperCase(), "2027-10-01"), a);
});
await check("no undated or unbound tokens", () => {
  assert.throws(() => signRamp(A));
  assert.throws(() => signRamp(A, ""));
  assert.throws(() => signRamp("ramp", "2027-10-01"));
  assert.throws(() => signRamp("", "2027-10-01"));
});

// Finding 7: order and replays.
subscriptions.sub_a = { status: "active", metadata: { install_id: A } };
await check("a late older payment can't roll a license back", async () => {
  await webhook(paid(A, "sub_a", unix(2028, 10, 1)));
  await webhook(paid(A, "sub_a", unix(2027, 10, 1)));
  const got = await license(A);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2028-10-01");
  assert.ok(verifies(got.body.token, `ramp:${A}:2028-10-01`));
});
await check("the refresh carries a signed server time bound to the install", async () => {
  const before = Math.floor(Date.now() / 1000);
  const got = await license(A);
  const after = Math.floor(Date.now() / 1000);
  const [, id, seconds] = tokenPayload(got.time).split(":");
  assert.equal(id, A.toLowerCase());
  assert.ok(Number(seconds) >= before && Number(seconds) <= after);
  assert.ok(verifies(got.time, `nightshift-time:${A.toLowerCase()}:${seconds}`));
  assert.ok(!verifies(got.time, `nightshift-time:${B.toLowerCase()}:${seconds}`));
  assert.equal(got.body.time, undefined);
  assert.equal(tokenPayload(signTime(A.toUpperCase(), 5)), `nightshift-time:${A.toLowerCase()}:5`);
  assert.throws(() => signTime("ramp", 5));
  assert.throws(() => signTime(A, -1));
  assert.throws(() => signTime(A, 1.5));
});
await check("renewal moves forward", async () => {
  await webhook(paid(A, "sub_a", unix(2029, 10, 1)));
  const got = await license(A);
  assert.equal(got.body.until, "2029-10-01");
  assert.ok(verifies(got.body.token, `ramp:${A}:2029-10-01`));
});

subscriptions.sub_b = { status: "active", metadata: { install_id: B } };
await check("a replayed or late payment can't re-enable a cancelled license", async () => {
  const first = paid(B, "sub_b", unix(2027, 10, 1));
  await webhook(first);
  assert.equal((await license(B)).status, 200);
  await webhook(deleted(B, "sub_b"));
  assert.equal((await license(B)).status, 204);
  // Stripe redelivers the same event (new signature, same id).
  await webhook(first);
  assert.equal((await license(B)).status, 204);
  // A different event for the deleted subscription, even with a later date.
  await webhook(paid(B, "sub_b", unix(2028, 10, 1)));
  assert.equal((await license(B)).status, 204);
});
await check("a new subscription after a cancellation works", async () => {
  subscriptions.sub_b2 = { status: "active", metadata: { install_id: B } };
  await webhook(paid(B, "sub_b2", unix(2028, 11, 1)));
  const got = await license(B);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2028-11-01");
});
await check("deleting an old subscription keeps the newer one", async () => {
  await webhook(deleted(B, "sub_b"));
  assert.equal((await license(B)).status, 200);
});
// N1: a new subscription takes over with its own day, even an earlier one.
await check("cancel a yearly plan, then buy monthly: licensed on the monthly", async () => {
  const G = "99999999-9999-4999-8999-999999999991";
  subscriptions.sub_gy = { status: "active", metadata: { install_id: G } };
  subscriptions.sub_gm = { status: "active", metadata: { install_id: G } };
  await webhook(paid(G, "sub_gy", unix(2028, 10, 10)));
  await webhook(deleted(G, "sub_gy"));
  assert.equal((await license(G)).status, 204);
  await webhook(paid(G, "sub_gm", unix(2027, 11, 10)));
  const got = await license(G);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2027-11-10");
  assert.ok(verifies(got.body.token, `ramp:${G}:2027-11-10`));
  // A late event from the deleted yearly plan changes nothing.
  await webhook(paid(G, "sub_gy", unix(2029, 10, 10)));
  assert.equal((await license(G)).body.until, "2027-11-10");
  // The monthly renews forward as usual.
  await webhook(paid(G, "sub_gm", unix(2027, 12, 10)));
  assert.equal((await license(G)).body.until, "2027-12-10");
});
await check("monthly bought before the yearly's deletion arrives", async () => {
  const H = "99999999-9999-4999-8999-999999999992";
  subscriptions.sub_hy = { status: "active", metadata: { install_id: H } };
  subscriptions.sub_hm = { status: "active", metadata: { install_id: H } };
  await webhook(paid(H, "sub_hy", unix(2028, 10, 10)));
  await webhook(paid(H, "sub_hm", unix(2027, 11, 10)));
  // Both live: the longer one counts.
  assert.equal((await license(H)).body.until, "2028-10-10");
  // A late yearly invoice can't take the row back from the monthly...
  await webhook(paid(H, "sub_hy", unix(2028, 10, 10)));
  // ...and the yearly's deletion falls back to the monthly, not to nothing.
  await webhook(deleted(H, "sub_hy"));
  const got = await license(H);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2027-11-10");
  assert.ok(verifies(got.body.token, `ramp:${H}:2027-11-10`));
  await webhook(deleted(H, "sub_hm"));
  assert.equal((await license(H)).status, 204);
});
// N7: a subscription Stripe doesn't have is acknowledged, not retried.
await check("an invoice for a missing subscription is acknowledged as cancelled", async () => {
  const M = "99999999-9999-4999-8999-999999999993";
  subscriptions.sub_m = { status: "active", metadata: { install_id: M } };
  await webhook(paid(M, "sub_m", unix(2028, 1, 1)));
  delete subscriptions.sub_m;
  await webhook(paid(M, "sub_m", unix(2029, 1, 1)));
  assert.equal((await license(M)).status, 204);
  await webhook(paid(M, "sub_gone", unix(2029, 1, 1)));
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.ok(stored.installs[M].canceled.includes("sub_m"));
  assert.ok(stored.installs[M].canceled.includes("sub_gone"));
});
await check("a transient Stripe error still fails, so Stripe retries", async () => {
  const T = "99999999-9999-4999-8999-999999999994";
  subscriptions.sub_t = { status: "active", metadata: { install_id: T } };
  unreachable.add("sub_t");
  const event = paid(T, "sub_t", unix(2028, 1, 1));
  await webhook(event, 502);
  unreachable.delete("sub_t");
  // Not recorded as seen: the retry is handled.
  await webhook(event);
  assert.equal((await license(T)).body.until, "2028-01-01");
});
await check("a subscription Stripe reports canceled doesn't unlock", async () => {
  subscriptions.sub_c = { status: "canceled", metadata: { install_id: C } };
  await webhook(paid(C, "sub_c", unix(2028, 10, 1)));
  assert.equal((await license(C)).status, 204);
});
await check("a redelivered event id is handled once", async () => {
  const F = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  subscriptions.sub_f = { status: "active", metadata: { install_id: F } };
  const once = paid(F, "sub_f", unix(2028, 10, 1), "evt_once");
  await webhook(once);
  // Changed by hand after the event: only the event id stops the redelivery
  // from writing it again (the date would otherwise move forward).
  saveLicense(F, { until: "2027-01-01", active: false });
  await webhook(once);
  const row = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8")).installs[F];
  assert.equal(row.until, "2027-01-01");
  assert.equal(row.active, false);
});
await check("event ids are recorded", () => {
  const store = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.ok(Object.keys(store.events).length >= eventCount - 1);
});

// N2: rows written before bound tokens held test tokens only; they are
// neither served nor re-signed.
await check("an unbound legacy row is not served", async () => {
  const legacy = Buffer.from("ramp:2027-10-01").toString("base64") + ".AAAA";
  saveLicense(D, {
    token: legacy,
    until: "2027-10-01",
    active: true,
    customer: "cus_d",
    secret_hash: sha(secretFor(D)),
  });
  assert.equal((await license(D)).status, 204);
  assert.equal(licenseFor(D), null);
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[D].token, legacy);
  // Nor can it be moved to another install to get a bound token.
  assert.equal(app.rebindLicense(D, C), "no license");
  // A row whose token names another install or day isn't served either.
  saveLicense(D, { token: signRamp(A, "2027-10-01") });
  assert.equal((await license(D)).status, 204);
  saveLicense(D, { token: signRamp(D, "2027-09-30") });
  assert.equal((await license(D)).status, 204);
  saveLicense(D, { token: signRamp(D, "2027-10-01") });
  assert.equal((await license(D)).status, 200);
});
await check("a revoked install gets 410", async () => {
  app.revokeLicense(D);
  assert.equal((await license(D)).status, 410);
});
await check("lapsed replies carry a signed server time", async () => {
  const at = timeFloor + 86400;
  useClockForTests(() => at);
  try {
    const revoked = await license(D);
    assert.equal(revoked.status, 410);
    assert.ok(verifies(revoked.time, `nightshift-time:${D.toLowerCase()}:${at}`));
    const lapsed = await license(D, null);
    assert.equal(lapsed.status, 204);
    assert.ok(verifies(lapsed.time, `nightshift-time:${D.toLowerCase()}:${at}`));
  } finally {
    useClockForTests(null);
  }
});
await check("no time is signed when the server clock is out of bounds", async () => {
  try {
    for (const at of [timeFloor - 1, timeCeiling + 1, 0, NaN]) {
      useClockForTests(() => at);
      const got = await license(D);
      assert.equal(got.status, 410);
      assert.equal(got.time, null);
    }
    for (const at of [timeFloor, timeCeiling]) {
      useClockForTests(() => at);
      assert.ok(verifies((await license(D)).time, `nightshift-time:${D.toLowerCase()}:${at}`));
    }
  } finally {
    useClockForTests(null);
  }
});

// Finding 10: the billing portal needs the install's secret.
const E = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const secret = "f".repeat(64);
const hash = createHash("sha256").update(secret).digest("hex");
async function checkout(installId, headerSecret) {
  const headers = { "Content-Type": "application/json" };
  if (headerSecret) {
    headers["X-Nightshift-Secret"] = headerSecret;
  }
  const response = await fetch(`${base}/checkout`, {
    method: "POST",
    headers,
    body: JSON.stringify({ install_id: installId }),
  });
  return { status: response.status, body: await response.json() };
}
await check("checkout records the secret's hash, never the secret", async () => {
  const got = await checkout(E, secret);
  assert.equal(got.status, 200);
  const params = created.at(-1);
  assert.equal(params.subscription_data.metadata.install_id, E);
  assert.equal(params.subscription_data.metadata.secret_hash, hash);
  assert.ok(!JSON.stringify(params).includes(secret));
  subscriptions.sub_e = {
    status: "active",
    metadata: { install_id: E, secret_hash: hash },
    customer: "cus_e",
  };
  await webhook(paid(E, "sub_e", unix(2028, 1, 1)));
  const portal = await checkout(E, secret);
  assert.equal(portal.status, 409);
  assert.equal(portal.body.url, "https://billing.stripe.com/p/session/cus_eeee");
  // Without the secret it isn't this Mac's license (R1): never the portal,
  // and (v5) no checkout either while that license is in force.
  const calls = stripeCalls.length;
  const other = await checkout(E, "0".repeat(64));
  assert.equal(other.status, 409);
  assert.deepEqual(other.body, { error: "contact support" });
  assert.equal(stripeCalls.length, calls);
  const none = await checkout(E, null);
  assert.equal(none.status, 400);
  assert.deepEqual(none.body, { error: "install secret" });
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[E].secret_hash, hash);
  assert.ok(!JSON.stringify(stored).includes(secret));
});
// N8: once a secret is on file, the license needs it.
await check("the license is served only with the install's secret", async () => {
  assert.equal((await license(E, null)).status, 204);
  assert.equal((await license(E)).status, 204);
  assert.equal((await license(E, "0".repeat(64))).status, 204);
  assert.equal((await license(E, "not hex")).status, 204);
  const got = await license(E, secret);
  assert.equal(got.status, 200);
  assert.ok(verifies(got.body.token, `ramp:${E}:2028-01-01`));
  // No GET, even with the secret: no lookup by install id in a URL.
  const get = await fetch(`${base}/license?install_id=${E}`, {
    headers: { "X-Nightshift-Secret": secret },
  });
  assert.equal(get.status, 404);
  // A row without a secret (none are made any more) is served to nobody.
  const N = "99999999-9999-4999-8999-99999999999b";
  saveLicense(N, { active: true, until: "2028-01-01", token: signRamp(N, "2028-01-01") });
  assert.equal(licenseFor(N).until, "2028-01-01");
  assert.equal((await license(N, null)).status, 204);
  assert.equal((await license(N)).status, 204);
});
// N3, R1: rebinding is admin-only (node admin.js rebind). It moves the
// license and leaves nothing behind at the old install id; Stripe events
// follow the subscription, not the install id in its metadata.
const E2 = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2";
await check("there is no HTTP rebind", async () => {
  const response = await fetch(`${base}/rebind`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Nightshift-Secret": secret },
    body: JSON.stringify({ from: E, install_id: E2 }),
  });
  assert.equal(response.status, 404);
});
await check("admin rebind moves the license and later payments follow it", async () => {
  const moved = app.rebindLicense(E, E2);
  assert.equal(moved.until, "2028-01-01");
  assert.ok(verifies(moved.token, `ramp:${E2}:2028-01-01`));
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[E], undefined);
  assert.equal((await license(E, secret)).status, 204);
  assert.equal((await license(E2, secret)).status, 200);
  assert.equal(app.rebindLicense(E, E2), "no license");
  // Stripe still names the old install id; the subscription decides.
  await webhook(paid(E, "sub_e", unix(2029, 1, 1)));
  const renewed = await license(E2, secret);
  assert.equal(renewed.body.until, "2029-01-01");
  assert.ok(verifies(renewed.body.token, `ramp:${E2}:2029-01-01`));
  assert.equal(licenseFor(E), null);
  await webhook(deleted(E, "sub_e"));
  assert.equal((await license(E2, secret)).status, 204);
});

// R1 (patch review v2): moving a license onto someone else's install id and
// off again must not capture that install's later purchase.
const attackerSecret = "1".repeat(64);
const victimSecret = "2".repeat(64);
// Runs fn, returning what it wrote with console.error (and not printing it).
async function capturingErrors(fn) {
  const logged = [];
  const kept = console.error;
  console.error = (...parts) => logged.push(parts.join(" "));
  try {
    await fn();
  } finally {
    console.error = kept;
  }
  return logged;
}
const storeOf = () => JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
function editStore(change) {
  const store = storeOf();
  change(store);
  writeFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, JSON.stringify(store));
}
const alertsPath = join(work, "alerts.jsonl");
const alerts = () =>
  existsSync(alertsPath)
    ? readFileSync(alertsPath, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line))
    : [];
async function buy(installId, buyerSecret, subscription, end) {
  const started = await checkout(installId, buyerSecret);
  assert.equal(started.status, 200, JSON.stringify(started.body));
  assert.equal(created.at(-1).subscription_data.metadata.secret_hash, sha(buyerSecret));
  subscriptions[subscription] = {
    status: "active",
    metadata: { install_id: installId, secret_hash: sha(buyerSecret) },
  };
  await webhook(paid(installId, subscription, end));
}
await check("a license moved onto a victim's id and away captures nothing", async () => {
  const A = "a1111111-1111-4111-8111-111111111111";
  const A2 = "a2222222-2222-4222-8222-222222222222";
  const V = "c3333333-3333-4333-8333-333333333333";
  await buy(A, attackerSecret, "sub_attacker", unix(2027, 3, 1));
  // Set up with the admin path, which both versions have.
  assert.equal(typeof app.rebindLicense(A, V), "object");
  assert.equal(typeof app.rebindLicense(V, A2), "object");
  assert.equal((await license(A2, attackerSecret)).body.until, "2027-03-01");
  // The victim buys on their own install id.
  await buy(V, victimSecret, "sub_victim", unix(2027, 6, 1));
  const mine = await license(V, victimSecret);
  assert.equal(mine.status, 200);
  assert.equal(mine.body.until, "2027-06-01");
  assert.ok(verifies(mine.body.token, `ramp:${V}:2027-06-01`));
  // The attacker's license is as it was, and has none of the victim's billing.
  const theirs = await license(A2, attackerSecret);
  assert.equal(theirs.body.until, "2027-03-01");
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.ok(!JSON.stringify(stored.installs[A2]).includes("sub_victim"));
  assert.notEqual(stored.installs[A2].customer, stored.installs[V].customer);
  for (const id of [A2, V]) {
    const portal = await checkout(id, attackerSecret);
    assert.ok(!String(portal.body.url).includes(stored.installs[V].customer), id);
  }
  assert.equal((await license(V, attackerSecret)).status, 204);
});
await check("a license moved onto a victim's id captures none of the victim's purchase", async () => {
  const B = "b4444444-4444-4444-8444-444444444444";
  const W = "c5555555-5555-4555-8555-555555555555";
  await buy(B, attackerSecret, "sub_attacker2", unix(2027, 3, 1));
  assert.equal(typeof app.rebindLicense(B, W, undefined), "object");
  // The victim can't use the attacker's license.
  assert.equal((await license(W, victimSecret)).status, 204);
  // v5: the install's license is in force under another secret, so its id
  // can't be bought from here (support moves one of them: admin.js rebind).
  const calls = stripeCalls.length;
  const refused = await checkout(W, victimSecret);
  assert.equal(refused.status, 409);
  assert.equal(refused.body.url, undefined);
  assert.equal(stripeCalls.length, calls);
  // A payment from an older checkout is held, refunded, and not given to
  // the attacker.
  subscriptions.sub_victim2 = {
    status: "active",
    metadata: { install_id: W, secret_hash: sha(victimSecret) },
  };
  const logged = await capturingErrors(() => webhook(paid(W, "sub_victim2", unix(2027, 6, 1))));
  assert.equal(logged.filter((line) => line.startsWith("MISMATCHED-PURCHASE")).length, 1);
  assert.ok(effects("refund").some(([, target]) => target.startsWith("pi_in_")));
  assert.ok(effects("cancel").some(([, target]) => target === "sub_victim2"));
  const theirs = await license(W, attackerSecret);
  assert.equal(theirs.body.until, "2027-03-01");
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.ok(!JSON.stringify(stored.installs[W]).includes("sub_victim2"));
  // The held buyer's Mac is told its purchase was refunded.
  assert.deepEqual((await license(W, victimSecret)).body, {
    error: "refunded",
    message: "This purchase was refunded; contact support",
  });
  const portal = await checkout(W, attackerSecret);
  assert.ok(!String(portal.body.url).includes("sub_victim2"));
});

await check("admin grants and rebinds", async () => {
  const K = "99999999-9999-4999-8999-999999999995";
  const K2 = "99999999-9999-4999-8999-999999999996";
  assert.equal(app.grantLicense(K, "not a day"), null);
  assert.equal(app.grantLicense(K, "2027-02-30"), null);
  const granted = app.grantLicense(K.toUpperCase(), "9999-12-31");
  assert.equal(granted.until, "9999-12-31");
  // A new secret, returned once; only its hash is stored.
  assert.match(granted.secret, /^[0-9a-f]{64}$/);
  let stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[K].secret_hash, sha(granted.secret));
  assert.ok(!JSON.stringify(stored).includes(granted.secret));
  assert.equal((await license(K)).status, 204);
  const got = await license(K, granted.secret);
  assert.ok(verifies(got.body.token, `ramp:${K}:9999-12-31`));
  // M1: a grant makes a new secret even when the row has one (it may be a
  // squatter's), and says so; --keep-secret keeps it.
  const regranted = app.grantLicense(K, "9999-12-31");
  assert.match(regranted.secret, /^[0-9a-f]{64}$/);
  assert.notEqual(regranted.secret, granted.secret);
  assert.equal(regranted.previous_secret.source, "grant");
  assert.equal((await license(K, granted.secret)).status, 204);
  assert.equal((await license(K, regranted.secret)).status, 200);
  const kept = app.grantLicense(K, "9999-12-31", { keepSecret: true });
  assert.equal(kept.secret, undefined);
  assert.equal(kept.previous_secret.source, "grant");
  assert.equal((await license(K, regranted.secret)).status, 200);
  assert.equal(app.rebindLicense(K, K2).until, "9999-12-31");
  assert.equal((await license(K, regranted.secret)).status, 204);
  assert.ok(verifies((await license(K2, regranted.secret)).body.token, `ramp:${K2}:9999-12-31`));
  stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[K], undefined);
});
await check("admin rebind refuses a destination with a license or a secret", async () => {
  const L = "99999999-9999-4999-8999-999999999997";
  const L2 = "99999999-9999-4999-8999-999999999998";
  const L3 = "99999999-9999-4999-8999-999999999999";
  const grantL = app.grantLicense(L, "2027-08-01");
  const grantL2 = app.grantLicense(L2, "2027-09-01");
  assert.equal(app.rebindLicense(L, L2), "destination has a license or a secret");
  assert.equal((await license(L2, grantL2.secret)).body.until, "2027-09-01");
  // An expired or cancelled row that still holds a Mac's secret counts too.
  saveLicense(L3, { secret_hash: sha("3".repeat(64)) });
  assert.equal(app.rebindLicense(L, L3), "destination has a license or a secret");
  assert.equal(app.rebindLicense(L, L3, { force: true }).until, "2027-08-01");
  const stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[L], undefined);
  assert.equal(stored.installs[L3].secret_hash, sha(grantL.secret));
  assert.equal(stored.archived.at(-1).install, L3);
  assert.ok(verifies((await license(L3, grantL.secret)).body.token, `ramp:${L3}:2027-08-01`));
});
// R2: a Mac that lost only its secret gets a new one from support.
await check("admin reset-secret makes a new secret, shown once", async () => {
  const R = "99999999-9999-4999-8999-99999999999a";
  const oldSecret = "4".repeat(64);
  await buy(R, oldSecret, "sub_r", unix(2027, 4, 1));
  const reset = app.resetSecret(R);
  assert.match(reset.secret, /^[0-9a-f]{64}$/);
  assert.equal(app.resetSecret("not an id"), null);
  assert.equal(app.resetSecret("99999999-9999-4999-8999-9999999999ff"), null);
  let stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[R].secret_hash, sha(reset.secret));
  assert.ok(!JSON.stringify(stored).includes(reset.secret));
  assert.equal((await license(R, oldSecret)).status, 204);
  const got = await license(R, reset.secret);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2027-04-01");
  // A renewal of the subscription doesn't bring the lost secret back.
  await webhook(paid(R, "sub_r", unix(2027, 5, 1)));
  stored = JSON.parse(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"));
  assert.equal(stored.installs[R].secret_hash, sha(reset.secret));
  assert.equal((await license(R, reset.secret)).body.until, "2027-05-01");
  assert.equal((await checkout(R, reset.secret)).status, 409);
});
await check("a grant gets only the portal's login link", async () => {
  const G2 = "99999999-9999-4999-8999-99999999999c";
  const granted = app.grantLicense(G2, "2027-12-01");
  assert.equal((await checkout(G2, granted.secret)).body.url, null);
  process.env.STRIPE_PORTAL_LOGIN_URL = "https://billing.stripe.com/p/login/test";
  const got = await checkout(G2, granted.secret);
  assert.equal(got.status, 409);
  assert.equal(got.body.url, "https://billing.stripe.com/p/login/test");
  delete process.env.STRIPE_PORTAL_LOGIN_URL;
});
// v3 leftover 1, v4 L2: only an admin --force rebind archives a row that
// still bills; that is a DOUBLE-BILLING alert for support, and nothing
// cancels the subscription. A purchase replaces only a row with no secret
// that nobody uses (v6 M1).
await check("a forced rebind over a billing row raises one DOUBLE-BILLING alert", async () => {
  const from = "99999999-9999-4999-8999-99999999999d";
  const X = "99999999-9999-4999-8999-99999999999f";
  const first = "6".repeat(64);
  await buy(from, attackerSecret, "sub_from", unix(2027, 7, 1));
  await buy(X, first, "sub_x_old", unix(2027, 7, 1));
  const changes = billingChanges.length;
  const logged = await capturingErrors(async () => {
    assert.equal(app.rebindLicense(from, X, { force: true }).until, "2027-07-01");
  });
  const line = `DOUBLE-BILLING: archived install ${X} still has active subscription sub_x_old; cancel it`;
  assert.deepEqual(logged.filter((text) => text.startsWith("DOUBLE-BILLING")), [line]);
  assert.deepEqual(
    alerts().filter((alert) => alert.kind === "DOUBLE-BILLING").map((alert) => alert.message),
    [line],
  );
  const stored = storeOf();
  assert.deepEqual(stored.archived.at(-1).still_billing, ["sub_x_old"]);
  assert.equal(billingChanges.length, changes);
});
await check("a purchase replaces an unused row with no secret, with no alert", async () => {
  const Y = "99999999-9999-4999-8999-99999999999e";
  // A row with no secret (from before secrets), lapsed and cancelled.
  saveLicense(Y, {
    periods: { sub_y_old: "2026-07-01" },
    canceled: ["sub_y_old"],
    until: "2026-07-01",
    active: false,
  });
  const before = alerts().length;
  await buy(Y, "7".repeat(64), "sub_y_new", unix(2027, 8, 1));
  assert.equal(alerts().length, before);
  assert.deepEqual(
    storeOf().archived.filter((entry) => entry.install === Y).at(-1).still_billing,
    [],
  );
  assert.equal((await license(Y, "7".repeat(64))).body.until, "2027-08-01");
});

// v6 M1: a lapsed customer's install id (secret on file, no live license
// or subscription) can't be taken over by a stranger's purchase.
const lapsedVictim = "e1111111-1111-4111-8111-111111111111";
const lapsedSecret = "c".repeat(64);
const lapsedStranger = "d".repeat(64);
let lapsedBefore;
await check("a stranger's checkout on a lapsed customer's id is refused", async () => {
  const V = lapsedVictim;
  // The stranger opens a checkout first; the victim then buys and lapses.
  const opened = await checkout(V, lapsedStranger);
  assert.equal(opened.status, 200);
  const metadata = created.at(-1).subscription_data.metadata;
  subscriptions.sub_m1 = {
    status: "active",
    metadata,
    customer: "cus_m1",
    items: { data: [{ current_period_end: unix(2027, 10, 1) }] },
  };
  checkoutSessions.cs_m1 = {
    status: "complete",
    payment_status: "paid",
    client_reference_id: V,
    subscription: "sub_m1",
    customer: "cus_m1",
    invoice: "in_cs_m1",
    metadata,
  };
  await buy(V, lapsedSecret, "sub_lapsed_v", unix(2026, 4, 1));
  await webhook(deleted(V, "sub_lapsed_v"));
  assert.equal((await license(V, lapsedSecret)).status, 204);
  lapsedBefore = JSON.stringify(storeOf().installs[V]);
  // A new checkout from the stranger is refused before any Stripe call.
  const calls = stripeCalls.length;
  const refused = await checkout(V, lapsedStranger);
  assert.equal(refused.status, 409);
  assert.deepEqual(refused.body, { error: "contact support" });
  assert.equal(stripeCalls.length, calls);
  assert.equal(JSON.stringify(storeOf().installs[V]), lapsedBefore);
});
await check("a stranger's late payment on a lapsed id is held and refunded", async () => {
  const V = lapsedVictim;
  const archivedBefore = (storeOf().archived || []).length;
  const changes = billingChanges.length;
  await capturingErrors(() => webhook(sessionPaid("cs_m1")));
  assert.equal(JSON.stringify(storeOf().installs[V]), lapsedBefore);
  assert.equal((storeOf().archived || []).length, archivedBefore);
  assert.deepEqual(billingChanges.slice(changes), [
    ["cancel", "sub_m1", "cancel-cs_m1"],
    ["refund", "pi_in_cs_m1", "refund-cs_m1"],
  ]);
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_m1").status, "refunded");
  assert.equal((await license(V, lapsedStranger)).body?.error, "refunded");
});
await check("the lapsed customer still buys again with their own secret", async () => {
  const V = lapsedVictim;
  await buy(V, lapsedSecret, "sub_back", unix(2027, 6, 1));
  const back = await license(V, lapsedSecret);
  assert.equal(back.status, 200);
  assert.equal(back.body.until, "2027-06-01");
  assert.ok(verifies(back.body.token, `ramp:${V}:2027-06-01`));
  assert.equal(storeOf().installs[V].secret_hash, sha(lapsedSecret));
});

// v5, H1: knowing an install id must not let anyone lock its Mac out by
// paying with their own secret.
const lockoutVictim = "d6666666-6666-4666-8666-666666666666";
const lockoutVictimSecret = "8".repeat(64);
const lockoutAttackerSecret = "9".repeat(64);
await check("the lockout purchase is refused at checkout, before any Stripe call", async () => {
  await buy(lockoutVictim, lockoutVictimSecret, "sub_lv", unix(2027, 9, 1));
  const before = readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8");
  const calls = stripeCalls.length;
  const sessions = created.length;
  const got = await checkout(lockoutVictim, lockoutAttackerSecret);
  assert.equal(got.status, 409);
  // Generic: nothing about the victim's license.
  assert.deepEqual(got.body, { error: "contact support" });
  assert.equal(stripeCalls.length, calls);
  assert.equal(created.length, sessions);
  assert.equal(readFileSync(process.env.NIGHTSHIFT_LICENSE_STORE, "utf8"), before);
  const mine = await license(lockoutVictim, lockoutVictimSecret);
  assert.equal(mine.status, 200);
  assert.equal(mine.body.until, "2027-09-01");
});

// The attack over HTTP: a checkout opened with the victim's id and the
// attacker's secret before the victim bought, paid afterwards.
function sessionPaid(sessionId, id = `evt_${++eventCount}`) {
  return eventObject(
    id,
    "checkout.session.completed",
    checkoutSessionObject(sessionId, checkoutSessions[sessionId]),
  );
}
async function openThenPay({ victim, victimSecret: theirs, attacker, sub, session, victimSub }) {
  const opened = await checkout(victim, attacker);
  assert.equal(opened.status, 200);
  const metadata = created.at(-1).subscription_data.metadata;
  await buy(victim, theirs, victimSub, unix(2027, 9, 1));
  subscriptions[sub] = {
    status: "active",
    metadata,
    customer: `cus_${sub}`,
    items: { data: [{ current_period_end: unix(2027, 10, 1) }] },
  };
  checkoutSessions[session] = {
    status: "complete",
    payment_status: "paid",
    client_reference_id: victim,
    subscription: sub,
    customer: `cus_${sub}`,
    invoice: `in_${session}`,
    metadata,
  };
}
await check("a lockout checkout paid later changes nothing for the victim", async () => {
  const V = "d7777777-7777-4777-8777-777777777777";
  const vSecret = "a".repeat(64);
  await openThenPay({
    victim: V,
    victimSecret: vSecret,
    attacker: lockoutAttackerSecret,
    sub: "sub_lock1",
    session: "cs_lock1",
    victimSub: "sub_v1",
  });
  const victimBefore = JSON.stringify(storeOf().installs[V]);
  const archivedBefore = (storeOf().archived || []).length;
  const changes = billingChanges.length;
  let returned;
  const logged = await capturingErrors(async () => {
    await webhook(sessionPaid("cs_lock1"));
    returned = await fetch(`${base}/success?session_id=cs_lock1`, { redirect: "manual" });
  });
  assert.equal(logged.filter((line) => line.startsWith("DOUBLE-BILLING")).length, 0);
  // The victim's row is exactly as it was, and still theirs.
  assert.equal(JSON.stringify(storeOf().installs[V]), victimBefore);
  assert.equal((storeOf().archived || []).length, archivedBefore);
  const mine = await license(V, vSecret);
  assert.equal(mine.body.until, "2027-09-01");
  assert.ok(verifies(mine.body.token, `ramp:${V}:2027-09-01`));
  // v5 L3: the held buyer is told, on /success and by /license.
  assert.equal(returned.status, 409);
  assert.equal(await returned.text(), "This purchase was refunded; contact support");
  assert.equal(returned.headers.get("location"), null);
  const told = await license(V, lockoutAttackerSecret);
  assert.equal(told.status, 409);
  assert.deepEqual(told.body, {
    error: "refunded",
    message: "This purchase was refunded; contact support",
  });
  // Nobody else learns anything.
  assert.equal((await license(V, "0".repeat(64))).status, 204);
  assert.equal((await license(V, null)).status, 204);
  // Only the attacker's new subscription and its payment were touched.
  assert.deepEqual(billingChanges.slice(changes), [
    ["cancel", "sub_lock1", "cancel-cs_lock1"],
    ["refund", "pi_in_cs_lock1", "refund-cs_lock1"],
  ]);
  const held = storeOf().held.find((entry) => entry.subscription === "sub_lock1");
  assert.equal(held.install, V);
  assert.equal(held.session, "cs_lock1");
  assert.equal(held.status, "refunded");
  assert.equal(storeOf().subscriptions.sub_lock1, null);
  const alert = alerts().filter((entry) => entry.kind === "MISMATCHED-PURCHASE" && entry.session === "cs_lock1");
  assert.equal(alert.length, 1);
  // The victim's renewals still land.
  await webhook(paid(V, "sub_v1", unix(2028, 9, 1)));
  assert.equal((await license(V, vSecret)).body.until, "2028-09-01");
  assert.equal(storeOf().installs[V].secret_hash, sha(vSecret));
});
await check("replays and a second event for a held session refund once", async () => {
  const V = "d8888888-8888-4888-8888-888888888888";
  await openThenPay({
    victim: V,
    victimSecret: "b".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock2",
    session: "cs_lock2",
    victimSub: "sub_v2",
  });
  const changes = billingChanges.length;
  const first = sessionPaid("cs_lock2");
  await capturingErrors(async () => {
    await webhook(first);
    await webhook(first);
    // Stripe's invoice.paid for the same purchase, a different event.
    await webhook(paid(V, "sub_lock2", unix(2027, 11, 1)));
  });
  const calls = billingChanges.slice(changes);
  assert.deepEqual(calls.filter(([kind]) => kind === "cancel"), [["cancel", "sub_lock2", "cancel-cs_lock2"]]);
  assert.deepEqual(calls.filter(([kind]) => kind === "refund"), [
    ["refund", "pi_in_cs_lock2", "refund-cs_lock2"],
  ]);
  assert.equal(alerts().filter((entry) => entry.session === "cs_lock2").length, 1);
  assert.equal((await license(V, "b".repeat(64))).body.until, "2027-09-01");
});
await check("a crash between the refund and its record doesn't refund twice", async () => {
  const V = "d9999999-9999-4999-8999-999999999999";
  await openThenPay({
    victim: V,
    victimSecret: "c".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock3",
    session: "cs_lock3",
    victimSub: "sub_v3",
  });
  const changes = billingChanges.length;
  const event = sessionPaid("cs_lock3");
  app.testHooks.afterRefund = () => {
    app.testHooks.afterRefund = null;
    throw new Error("crash after the refund");
  };
  await capturingErrors(() => webhook(event, 500));
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_lock3").status, "pending");
  // Stripe retries the event: the same keys, so nothing is done twice.
  await capturingErrors(() => webhook(event));
  const calls = billingChanges.slice(changes);
  assert.equal(calls.filter(([kind]) => kind === "refund").length, 2);
  assert.ok(calls.every(([kind, , key]) => key === `${kind}-cs_lock3`));
  assert.deepEqual(effects("refund").filter(([, target]) => target === "pi_in_cs_lock3").length, 1);
  assert.deepEqual(effects("cancel").filter(([, target]) => target === "sub_lock3").length, 1);
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_lock3").status, "refunded");
  assert.equal(alerts().filter((entry) => entry.session === "cs_lock3").length, 1);
});
await check("a failed refund stays held, alerts once, and is retried", async () => {
  const V = "daaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  await openThenPay({
    victim: V,
    victimSecret: "d".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock4",
    session: "cs_lock4",
    victimSub: "sub_v4",
  });
  failingRefunds.add("pi_in_cs_lock4");
  const event = sessionPaid("cs_lock4");
  await capturingErrors(async () => {
    await webhook(event, 502);
    await webhook(event, 502);
  });
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_lock4").status, "failed");
  const failed = alerts().filter((entry) => entry.kind === "REFUND-FAILED" && entry.session === "cs_lock4");
  assert.equal(failed.length, 1);
  failingRefunds.delete("pi_in_cs_lock4");
  await capturingErrors(() => webhook(event));
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_lock4").status, "refunded");
  assert.equal(effects("refund").filter(([, target]) => target === "pi_in_cs_lock4").length, 1);
  assert.equal((await license(V, "d".repeat(64))).body.until, "2027-09-01");
});

// v5 L1: a retry after Stripe's idempotency keys expired finds the
// cancel and refund already done, and treats that as success.
await check("a retry past the idempotency window finishes without a second refund", async () => {
  const V = "deeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  await openThenPay({
    victim: V,
    victimSecret: "5".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock6",
    session: "cs_lock6",
    victimSub: "sub_v6",
  });
  const event = sessionPaid("cs_lock6");
  app.testHooks.afterRefund = () => {
    app.testHooks.afterRefund = null;
    throw new Error("crash after the refund");
  };
  await capturingErrors(() => webhook(event, 500));
  // More than 24 hours later: Stripe has forgotten the keys.
  billingDone.delete("cancel-cs_lock6");
  billingDone.delete("refund-cs_lock6");
  await capturingErrors(() => webhook(event));
  const held = storeOf().held.find((entry) => entry.subscription === "sub_lock6");
  assert.equal(held.status, "refunded");
  assert.equal(alerts().filter((entry) => entry.kind === "REFUND-FAILED" && entry.session === "cs_lock6").length, 0);
  assert.ok(refundedPayments.has("pi_in_cs_lock6"));
  assert.equal(
    billingChanges.filter(([kind, target]) => kind === "refund" && target === "pi_in_cs_lock6").length,
    2,
  );
});

// v8: at the pinned API version an invoice carries no payment fields
// (the sandbox run found v7 cancelling but never refunding). The payment
// comes from Stripe, through the invoice the server resolved itself.
const heldSuccess = (session) =>
  fetch(`${base}/success?session_id=${session}`, { redirect: "manual" });
await check("a held purchase's payment comes from its expanded invoice", async () => {
  const V = "e7777777-7777-4777-8777-777777777771";
  await openThenPay({
    victim: V,
    victimSecret: "6".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock7",
    session: "cs_lock7",
    victimSub: "sub_v7",
  });
  const event = sessionPaid("cs_lock7");
  assert.equal(event.api_version, stripeApiVersion);
  assert.equal(event.data.object.payment_intent, null);
  const changes = billingChanges.length;
  const calls = invoiceCalls.length;
  await capturingErrors(() => webhook(event));
  assert.deepEqual(invoiceCalls.slice(calls), [["retrieve", "in_cs_lock7", ["payments"]]]);
  assert.deepEqual(billingChanges.slice(changes), [
    ["cancel", "sub_lock7", "cancel-cs_lock7"],
    ["refund", "pi_in_cs_lock7", "refund-cs_lock7"],
  ]);
  const held = storeOf().held.find((entry) => entry.subscription === "sub_lock7");
  assert.equal(held.status, "refunded");
  assert.equal(held.invoice, "in_cs_lock7");
  assert.deepEqual(held.payment, { payment_intent: "pi_in_cs_lock7" });
  assert.equal((await license(V, "6".repeat(64))).body.until, "2027-09-01");
});
await check("invoice.paid first, with the payment only in the invoice's payments list", async () => {
  const V = "e7777777-7777-4777-8777-777777777772";
  await openThenPay({
    victim: V,
    victimSecret: "7".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock8",
    session: "cs_lock8",
    victimSub: "sub_v8",
  });
  listOnlyInvoices.add("in_cs_lock8");
  // Stripe sent invoice.paid before checkout.session.completed in the
  // sandbox, and the event's invoice has no payment fields at all.
  const first = paid(V, "sub_lock8", unix(2027, 10, 1));
  const invoice = first.data.object;
  for (const field of ["payment_intent", "charge", "payments"]) {
    assert.ok(!(field in invoice), field);
  }
  const changes = billingChanges.length;
  const calls = invoiceCalls.length;
  await capturingErrors(async () => {
    await webhook(first);
    await webhook(sessionPaid("cs_lock8"));
    await webhook(first);
  });
  // The invoice is the one the checkout session made, not the event's.
  assert.deepEqual(invoiceCalls.slice(calls), [
    ["retrieve", "in_cs_lock8", ["payments"]],
    ["list", "in_cs_lock8"],
  ]);
  assert.deepEqual(
    billingChanges.slice(changes).filter(([kind]) => kind === "refund"),
    [["refund", "pi_in_cs_lock8", "refund-cs_lock8"]],
  );
  assert.equal(effects("refund").filter(([, target]) => target === "pi_in_cs_lock8").length, 1);
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_lock8").status, "refunded");
  assert.equal(alerts().filter((entry) => entry.session === "cs_lock8").length, 1);
});
await check("an invoice that bills another subscription is not refunded", async () => {
  const V = "e7777777-7777-4777-8777-777777777773";
  await openThenPay({
    victim: V,
    victimSecret: "1".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock9",
    session: "cs_lock9",
    victimSub: "sub_v9",
  });
  invoiceOwners.in_cs_lock9 = "sub_v9";
  await capturingErrors(() => webhook(sessionPaid("cs_lock9"), 500));
  assert.equal(effects("refund").filter(([, target]) => target === "pi_in_cs_lock9").length, 0);
  assert.equal(storeOf().held.find((entry) => entry.subscription === "sub_lock9").status, "failed");
  assert.equal(
    alerts().filter((entry) => entry.kind === "REFUND-FAILED" && entry.session === "cs_lock9").length,
    1,
  );
  assert.equal((await license(V, lockoutAttackerSecret)).body.error, "pending");
  assert.equal(storeOf().installs[V].secret_hash, sha("1".repeat(64)));
});
await check("the held buyer is told pending until the refund succeeds, then refunded", async () => {
  const V = "e7777777-7777-4777-8777-777777777774";
  await openThenPay({
    victim: V,
    victimSecret: "2".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock10",
    session: "cs_lock10",
    victimSub: "sub_v10",
  });
  failingRefunds.add("pi_in_cs_lock10");
  let early;
  await capturingErrors(async () => {
    await webhook(sessionPaid("cs_lock10"), 502);
    early = await heldSuccess("cs_lock10");
  });
  const pending = { error: "pending", message: "This purchase is being reversed; contact support" };
  assert.equal(early.status, 409);
  assert.equal(await early.text(), pending.message);
  assert.deepEqual((await license(V, lockoutAttackerSecret)).body, pending);
  assert.equal((await license(V, null)).status, 204);
  failingRefunds.delete("pi_in_cs_lock10");
  let late;
  await capturingErrors(async () => {
    late = await heldSuccess("cs_lock10");
  });
  assert.equal(late.status, 409);
  assert.equal(await late.text(), "This purchase was refunded; contact support");
  assert.deepEqual((await license(V, lockoutAttackerSecret)).body, {
    error: "refunded",
    message: "This purchase was refunded; contact support",
  });
  assert.equal(effects("refund").filter(([, target]) => target === "pi_in_cs_lock10").length, 1);
  assert.equal((await license(V, "2".repeat(64))).body.until, "2027-09-01");
});
await check("events in another API version are handled and logged once", async () => {
  const other = { ...deleted(A, "sub_nobody"), api_version: "2024-06-20" };
  const logged = await capturingErrors(async () => {
    await webhook(other);
    await webhook({ ...other, id: `evt_${++eventCount}` });
  });
  assert.equal(logged.filter((line) => line.startsWith("WEBHOOK-VERSION: event api_version 2024-06-20")).length, 1);
});
// v8.1: personal fields a recapture could leak (names, phone numbers,
// addresses, card fingerprints) must be null in every fixture. A country,
// the public test card's last4 (4242) and *_check results may stay.
const personalKey = (key) =>
  key === "name" ||
  key.endsWith("_name") ||
  key === "phone" ||
  key.endsWith("_phone") ||
  ["line1", "line2", "postal_code", "city", "state", "fingerprint"].includes(key);
function personalLeaks(value, path = "") {
  if (Array.isArray(value)) {
    return value.flatMap((entry, index) => personalLeaks(entry, `${path}[${index}]`));
  }
  if (!value || typeof value !== "object") {
    return [];
  }
  return Object.entries(value).flatMap(([key, entry]) => {
    const at = path ? `${path}.${key}` : key;
    if (personalKey(key)) {
      return entry === null ? [] : [at];
    }
    if (key === "last4") {
      return entry === null || entry === "4242" ? [] : [at];
    }
    return personalLeaks(entry, at);
  });
}
await check("the Stripe fixtures are the pinned version and carry nothing secret", () => {
  assert.equal(fixtureApiVersion, stripeApiVersion);
  const names = fixtureNames();
  for (const needed of ["invoice", "invoice-expand-payments", "invoice-payments-list", "refund"]) {
    assert.ok(names.includes(needed), needed);
  }
  const invoice = fixture("invoice");
  for (const field of ["payment_intent", "charge", "payments"]) {
    assert.ok(!(field in invoice), field);
  }
  assert.ok(!("payments" in fixture("event-invoice-paid").data.object));
  for (const name of names) {
    const text = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), "fixtures", "stripe-2026-03-25", `${name}.json`),
      "utf8",
    );
    const parsed = JSON.parse(text);
    if (parsed.object === "event") {
      assert.equal(parsed.api_version, stripeApiVersion, name);
      assert.equal(parsed.livemode, false, name);
    }
    assert.ok(!/(sk|rk|pk)_(test|live)_|whsec_|_secret_/.test(text), name);
    assert.ok(!/"client_secret":\s*"/.test(text), name);
    assert.ok(!/https?:\/\/(?!example\.invalid\/)/.test(text), name);
    assert.ok(!/@(?!example\.invalid")/.test(text), name);
    assert.ok(!/"livemode":\s*true/.test(text), name);
    assert.deepEqual(personalLeaks(parsed), [], name);
    // No transaction references or other long numbers kept as strings.
    assert.ok(!/"(?!0+")[0-9]{10,}"/.test(text), name);
    // Every Stripe id is a stable fake.
    for (const id of text.match(/"[a-z]+_(?:test_)?[A-Za-z0-9]{10,}"/g) || []) {
      assert.match(id, /fixture\d{4}"$|_[a-z_]+"$/, `${name} ${id}`);
    }
  }
});

// v5 H1: a Mac holding its install's secret buys again once its license
// has lapsed, including right after support's reset-secret.
await check("an expired customer buys again", async () => {
  const X = "dfffffff-ffff-4fff-8fff-ffffffffffff";
  const mine = "3".repeat(64);
  await buy(X, mine, "sub_lapsed", unix(2026, 3, 1));
  assert.equal((await license(X, mine)).status, 204);
  await buy(X, mine, "sub_again", unix(2027, 3, 1));
  const got = await license(X, mine);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2027-03-01");
  assert.ok(verifies(got.body.token, `ramp:${X}:2027-03-01`));
  assert.equal(storeOf().installs[X].secret_hash, sha(mine));
});
await check("a customer buys again after reset-secret", async () => {
  const X = "e0000000-0000-4000-8000-000000000001";
  // Lapsed, its subscription not yet cancelled: still in use, so a
  // stranger (or the lost secret) can't buy it.
  await buy(X, "4".repeat(64), "sub_lost", unix(2026, 2, 1));
  const reset = app.resetSecret(X);
  assert.deepEqual((await checkout(X, "4".repeat(64))).body, { error: "contact support" });
  await buy(X, reset.secret, "sub_found", unix(2027, 2, 1));
  const got = await license(X, reset.secret);
  assert.equal(got.status, 200);
  assert.equal(got.body.until, "2027-02-01");
  assert.equal(storeOf().installs[X].secret_hash, sha(reset.secret));
});

// v4 L1: /success hands out the token once, within an hour.
await check("/success serves the token once, and only within an hour", async () => {
  const S = "dbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const S2 = "dccccccc-cccc-4ccc-8ccc-cccccccccccc";
  for (const [id, sub, session] of [
    [S, "sub_s", "cs_s"],
    [S2, "sub_s2", "cs_s2"],
  ]) {
    await buy(id, secretFor(id), sub, unix(2027, 5, 1));
    checkoutSessions[session] = {
      status: "complete",
      payment_status: "paid",
      client_reference_id: id,
      subscription: sub,
      metadata: { secret_hash: sha(secretFor(id)) },
    };
  }
  const success = (session) => fetch(`${base}/success?session_id=${session}`, { redirect: "manual" });
  const once = await success("cs_s");
  assert.equal(once.status, 302);
  assert.ok(once.headers.get("location").startsWith("nightshift://license?token="));
  assert.equal((await success("cs_s")).status, 202);
  // Seen paid more than an hour ago: no token, even the first time.
  await webhook(sessionPaid("cs_s2"));
  editStore((store) => {
    store.sessions.cs_s2.completed_at -= 3601;
  });
  assert.equal((await success("cs_s2")).status, 202);
  // The app still gets it from /license, with its secret.
  assert.equal((await license(S2)).body.until, "2027-05-01");
});

// v4 L2: alerts reach support, with no secrets in them.
await check("alerts go to alerts.jsonl and the support webhook, without secrets", async () => {
  const received = [];
  const hook = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      received.push(JSON.parse(body));
      res.end();
    });
  });
  await new Promise((resolve) => hook.listen(0, "127.0.0.1", resolve));
  process.env.SUPPORT_ALERT_WEBHOOK_URL = `http://127.0.0.1:${hook.address().port}/alerts`;
  const V = "dddddddd-1111-4111-8111-dddddddddddd";
  await openThenPay({
    victim: V,
    victimSecret: "e".repeat(64),
    attacker: lockoutAttackerSecret,
    sub: "sub_lock5",
    session: "cs_lock5",
    victimSub: "sub_v5",
  });
  try {
    await capturingErrors(() => webhook(sessionPaid("cs_lock5")));
    await app.flushAlerts();
  } finally {
    delete process.env.SUPPORT_ALERT_WEBHOOK_URL;
    hook.close();
  }
  assert.equal(received.length, 1);
  assert.equal(received[0].kind, "MISMATCHED-PURCHASE");
  assert.equal(received[0].session, "cs_lock5");
  assert.ok(received[0].message.startsWith("MISMATCHED-PURCHASE: install "));
  const text = readFileSync(alertsPath, "utf8");
  const stored = storeOf();
  const hashes = [
    ...Object.values(stored.installs).map((row) => row.secret_hash),
    ...[lockoutAttackerSecret, lockoutVictimSecret, attackerSecret, victimSecret].flatMap((s) => [s, sha(s)]),
  ].filter(Boolean);
  for (const value of hashes) {
    assert.ok(!text.includes(value));
  }
  const listed = spawnSync(process.execPath, ["admin.js", "alerts"], {
    cwd: dirname(fileURLToPath(import.meta.url)),
    env: process.env,
    encoding: "utf8",
  });
  assert.equal(listed.status, 0, listed.stderr);
  assert.ok(listed.stdout.includes("MISMATCHED-PURCHASE: install dddddddd-1111"), listed.stdout);
  assert.ok(listed.stdout.includes("DOUBLE-BILLING: archived install"));
  assert.ok(listed.stdout.includes(`alerts in ${alertsPath}`));
});

// Finding 11: generic errors.
await check("Stripe errors don't leak", async () => {
  const response = await fetch(`${base}/success?session_id=x`);
  assert.equal(response.status, 502);
  const text = await response.text();
  assert.ok(!text.includes("secret-detail"), text);
  assert.ok(!text.includes("No such"), text);
});
await check("bad JSON is a plain 400", async () => {
  const response = await fetch(`${base}/checkout`, { method: "POST", body: "{" });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "bad request" });
});
await check("a bad webhook signature is a plain 400", async () => {
  const response = await fetch(`${base}/webhook`, {
    method: "POST",
    headers: { "Stripe-Signature": "t=1,v1=00" },
    body: "{}",
  });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "bad request" });
});
await check("an unreadable store is a plain 503 and is left alone", async () => {
  const kept = process.env.NIGHTSHIFT_LICENSE_STORE;
  const corrupt = join(work, "corrupt.json");
  writeFileSync(corrupt, "{");
  process.env.NIGHTSHIFT_LICENSE_STORE = corrupt;
  const got = await fetch(`${base}/license`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Nightshift-Secret": secretFor(A) },
    body: JSON.stringify({ install_id: A }),
  });
  assert.equal(got.status, 503);
  assert.deepEqual(await got.json(), { error: "service unavailable" });
  assert.equal(readFileSync(corrupt, "utf8"), "{");
  process.env.NIGHTSHIFT_LICENSE_STORE = kept;
});

// .env.example is committed and copied into .env, so it must never carry a
// secret. Its defaults (cents, base URL, port) stay; any key whose name holds
// SECRET, KEY or TOKEN must be empty, no value may start with sk_, rk_ or
// whsec_, and no line may match the pre-commit hook's patterns
// (scripts/secret-patterns.txt). Same KEY=value grammar as loadEnv; comments
// and blank lines are skipped. A failure names the key (or the line number),
// never the value.
await check(".env.example carries no secrets", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const patterns = readFileSync(join(here, "..", "scripts", "secret-patterns.txt"), "utf8")
    .split("\n")
    .filter((line) => line.trim() !== "" && !line.startsWith("#"))
    .map((line) => new RegExp(line));
  assert.ok(patterns.length > 0);
  const found = [];
  readFileSync(join(here, ".env.example"), "utf8")
    .split(/\r?\n/)
    .forEach((line, index) => {
      const text = line.trim();
      if (text === "" || text.startsWith("#")) return;
      const match = text.match(/^([A-Z0-9_]+)=(.*)$/);
      const name = match ? match[1] : `line ${index + 1}`;
      const value = match ? match[2].trim() : text;
      if (match && /SECRET|KEY|TOKEN/.test(name) && value !== "") {
        found.push(`${name} must be empty`);
      } else if (/^["']?(sk_|rk_|whsec_)/.test(value)) {
        found.push(`${name} holds a Stripe secret prefix`);
      } else if (patterns.some((pattern) => pattern.test(text))) {
        found.push(`${name} looks like a Stripe secret`);
      } else if (!match) {
        found.push(`${name} isn't KEY=value`);
      }
    });
  assert.ok(found.length === 0, `.env.example: ${found.join("; ")}`);
});

server.close();
console.log(`server ok (${passed} checks)`);
