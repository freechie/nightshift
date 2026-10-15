import { createHash, createPrivateKey, randomBytes, sign, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import {
  appendFileSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Stripe from "stripe";

const root = dirname(fileURLToPath(import.meta.url));
export const envPath = join(root, ".env");
function storeFile() {
  return process.env.NIGHTSHIFT_LICENSE_STORE || join(root, "data", "licenses.json");
}
const idPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function loadEnv() {
  try {
    for (const line of readFileSync(envPath, "utf8").split("\n")) {
      const match = line.match(/^([A-Z0-9_]+)=(.*)$/);
      if (match && !process.env[match[1]]) {
        process.env[match[1]] = match[2];
      }
    }
  } catch {
    // A missing .env is fine when the variables are already set.
  }
}

export function licenseKeyPath() {
  return (
    process.env.NIGHTSHIFT_LICENSE_KEY ||
    join(process.env.HOME, ".nightshift", "license.pem")
  );
}

export function publicBase() {
  return (process.env.PUBLIC_BASE_URL || "http://127.0.0.1:8787").replace(
    /\/$/,
    "",
  );
}

// v8: every Stripe client is pinned to the API version this server was
// checked against in a Stripe sandbox (the shapes of invoices, payments
// and events differ between versions; test fixtures are captured from it).
// Changing it means re-running the sandbox check (README, "License server").
export const stripeApiVersion = "2026-03-25.dahlia";

// Events Stripe sends in another API version than the pinned one (an
// endpoint or listener created elsewhere) are still handled, and logged
// once per version so it gets fixed.
const warnedVersions = new Set();
function warnApiVersion(version) {
  if (typeof version !== "string" || version === stripeApiVersion || warnedVersions.has(version)) {
    return;
  }
  warnedVersions.add(version);
  console.error(
    `WEBHOOK-VERSION: event api_version ${version}, server pinned ${stripeApiVersion}; ` +
      "set the endpoint's API version to match",
  );
}

export function stripeClient() {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) {
    return null;
  }
  const options = { apiVersion: stripeApiVersion };
  if (process.env.STRIPE_API_HOST) {
    options.host = process.env.STRIPE_API_HOST;
    options.port = Number(process.env.STRIPE_API_PORT || 12111);
    options.protocol = "http";
  }
  return new Stripe(key, options);
}

// Finding 6: a token names the install it unlocks, so it is unique per
// install, useless anywhere else, and traceable to its row.
//   payload: ramp:<install_id>:<YYYY-MM-DD>   (lower-case install id)
export function signRamp(installId, day) {
  if (!idPattern.test(installId || "")) {
    throw new Error("bad install id");
  }
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(day || "")) {
    throw new Error("bad ramp date");
  }
  return signPayload(`ramp:${installId.toLowerCase()}:${day}`);
}

function signPayload(text) {
  const payload = Buffer.from(text);
  const key = createPrivateKey(readFileSync(licenseKeyPath()));
  if (key.asymmetricKeyType !== "ed25519") {
    throw new Error("license key is not Ed25519");
  }
  const signature = sign(null, payload, key);
  return `${payload.toString("base64")}.${signature.toString("base64")}`;
}

// The server's clock, for the app's expiry check, so setting a Mac's clock
// back can't keep an expired license alive. Bound to the install so it
// can't be replayed on another Mac.
//   payload: nightshift-time:<install_id>:<unix seconds>   (lower-case id)
export function signTime(installId, seconds = Math.floor(Date.now() / 1000)) {
  if (!idPattern.test(installId || "")) {
    throw new Error("bad install id");
  }
  if (!Number.isSafeInteger(seconds) || seconds < 0) {
    throw new Error("bad time");
  }
  return signPayload(`nightshift-time:${installId.toLowerCase()}:${seconds}`);
}

// A sanity bound on the server's own clock. A Mac keeps the newest signed
// time it has seen, so one signed far ahead would expire its license for
// good; a time before this code existed means the clock is unset. Outside
// the bound no time is sent, and the app falls back to its own clock. Move
// both dates forward together, in a release, before the ceiling.
export const timeFloor = Date.UTC(2026, 9, 1) / 1000; // 2026-10-01
export const timeCeiling = Date.UTC(2036, 9, 1) / 1000; // floor + 10 years
const systemClock = () => Math.floor(Date.now() / 1000);
let clock = systemClock;
export function useClockForTests(next) {
  clock = next || systemClock;
}

// The signed time for a /license reply, or null: out of bounds, or the
// key can't be read. Never an error, so a lapsed reply still goes out.
export function serverTimeToken(installId) {
  const now = clock();
  if (!Number.isSafeInteger(now) || now < timeFloor || now > timeCeiling) {
    return null;
  }
  try {
    return signTime(installId, now);
  } catch {
    return null;
  }
}

// The payload a token carries, or null.
export function tokenPayload(token) {
  if (typeof token !== "string") {
    return null;
  }
  const dot = token.indexOf(".");
  if (dot <= 0) {
    return null;
  }
  return Buffer.from(token.slice(0, dot), "base64").toString("utf8");
}

function tokenBoundTo(token, installId, until) {
  return tokenPayload(token) === `ramp:${installId.toLowerCase()}:${until}`;
}

export function secretHash(secret) {
  if (typeof secret !== "string" || !/^[0-9a-f]{64}$/.test(secret)) {
    return null;
  }
  return createHash("sha256").update(secret).digest("hex");
}

function sameHash(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) {
    return false;
  }
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

export function utcDate(unix) {
  const date = new Date(unix * 1000);
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${date.getUTCFullYear()}-${month}-${day}`;
}

class StoreError extends Error {}

function readStore() {
  const path = storeFile();
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      return { installs: {} };
    }
    throw error;
  }
  let store;
  try {
    store = JSON.parse(text);
  } catch {
    throw new StoreError("license store is unreadable");
  }
  if (
    store == null ||
    typeof store !== "object" ||
    Array.isArray(store) ||
    store.installs == null ||
    typeof store.installs !== "object" ||
    Array.isArray(store.installs) ||
    (store.events != null && (typeof store.events !== "object" || Array.isArray(store.events))) ||
    (store.subscriptions != null &&
      (typeof store.subscriptions !== "object" || Array.isArray(store.subscriptions))) ||
    (store.archived != null && !Array.isArray(store.archived))
  ) {
    throw new StoreError("license store is unreadable");
  }
  return store;
}

function writeStore(store) {
  const path = storeFile();
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(store, null, 2)}\n`, { mode: 0o600 });
  renameSync(tmp, path);
}

function withStore(change) {
  const lock = `${storeFile()}.lock`;
  mkdirSync(dirname(lock), { recursive: true });
  const started = Date.now();
  for (;;) {
    try {
      mkdirSync(lock);
      break;
    } catch (error) {
      if (error.code !== "EEXIST") {
        throw error;
      }
      let age = 0;
      try {
        age = Date.now() - statSync(lock).mtimeMs;
      } catch {
        age = 0;
      }
      if (age > 5000) {
        rmSync(lock, { recursive: true, force: true });
        continue;
      }
      if (Date.now() - started > 5000) {
        throw new StoreError("license store is locked");
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
    }
  }
  try {
    const store = readStore();
    const saved = change(store);
    writeStore(store);
    return saved;
  } finally {
    rmSync(lock, { recursive: true, force: true });
  }
}

export function saveLicense(installId, fields) {
  return withStore((store) => {
    store.installs[installId] = {
      ...(store.installs[installId] || {}),
      ...fields,
    };
    return store.installs[installId];
  });
}

function utcToday() {
  return new Date().toISOString().slice(0, 10);
}

// The install's current license, or null. Only a token bound to this
// install and the row's day counts (finding 6, N2): rows holding an old
// unbound "ramp:<day>" token were test rows and are not served.
export function licenseFor(installId) {
  const row = readStore().installs[installId];
  return liveLicense(row, installId) ? row : null;
}

// Whether a row holds a license that is in force today: active, not
// revoked, unexpired, with a token bound to this install.
function liveLicense(row, installId) {
  if (!row || !row.active || row.revoked || typeof row.until !== "string") {
    return false;
  }
  return row.until >= utcToday() && tokenBoundTo(row.token, installId, row.until);
}

// Whether an install's row is someone's: its license is active (even past
// its day) or one of its subscriptions hasn't been cancelled. Such a row is
// never archived or changed for a purchase with another secret (v5, H1:
// anyone who knows an install id could otherwise pay once to lock its Mac
// out), and its install id can't be bought from another Mac.
function liveSubscriptions(row) {
  const canceled = Array.isArray(row.canceled) ? row.canceled : [];
  return [...new Set([...Object.keys(row.periods || {}), row.subscription])].filter(
    (subscription) => subscription && !canceled.includes(subscription),
  );
}
function rowInUse(row, installId) {
  return Boolean(
    row && (row.active === true || liveLicense(row, installId) || liveSubscriptions(row).length > 0),
  );
}
// v6 M1: whether a row belongs to someone against another secret. Any row
// holding a Mac's secret does, lapsed or not, so a lapsed customer's
// install id can't be bought out from under them (they buy again with their
// own secret; one who lost it gets a new one from support: reset-secret).
// A row with no secret (none are made any more) is claimed only while in
// use.
function rowClaimed(row, installId) {
  return Boolean(row && (row.secret_hash || rowInUse(row, installId)));
}

// v5: purchases set aside because they were paid with another secret for
// an install in use (from a checkout opened before that install's row
// existed or while it was unused). Each is the buyer's own new
// subscription; it is cancelled and its payment refunded (settleHeld).
// Nothing else is touched.
function heldList(store) {
  if (!Array.isArray(store.held)) {
    store.held = [];
  }
  return store.held;
}
function heldEntry(subscription) {
  return heldList(readStore()).find((entry) => entry.subscription === subscription) || null;
}

// v5, L2: alerts support must act on, appended to alerts.jsonl next to the
// store (server/data/alerts.jsonl) and, when SUPPORT_ALERT_WEBHOOK_URL is
// set, POSTed there as JSON. One alert per kind and key (a checkout session,
// or an install and subscription). Alerts carry ids only, never a secret or
// a secret's hash.
export function alertsFile() {
  return process.env.NIGHTSHIFT_ALERTS_FILE || join(dirname(storeFile()), "alerts.jsonl");
}
export function listAlerts() {
  let text = "";
  try {
    text = readFileSync(alertsFile(), "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
  const alerts = [];
  for (const line of text.split("\n")) {
    try {
      if (line.trim()) {
        alerts.push(JSON.parse(line));
      }
    } catch {
      // A torn last line from a crash is skipped.
    }
  }
  return alerts;
}
const deliveries = new Set();
function raiseAlert(kind, key, message, details = {}) {
  const dedupe = `${kind}:${key}`;
  // The line is also logged, so it stays greppable in the server log.
  console.error(message);
  try {
    if (listAlerts().some((alert) => alert.dedupe === dedupe)) {
      return false;
    }
    const alert = { at: new Date().toISOString(), kind, dedupe, message, ...details };
    mkdirSync(dirname(alertsFile()), { recursive: true });
    appendFileSync(alertsFile(), `${JSON.stringify(alert)}\n`, { mode: 0o600 });
    const hook = process.env.SUPPORT_ALERT_WEBHOOK_URL;
    if (hook) {
      const delivery = fetch(hook, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(alert),
        signal: AbortSignal.timeout(5000),
      })
        .then((response) => {
          if (!response.ok) {
            console.error(`support alert webhook: HTTP ${response.status}`);
          }
        })
        .catch((error) => console.error(`support alert webhook: ${error?.message}`))
        .finally(() => deliveries.delete(delivery));
      deliveries.add(delivery);
    }
    return true;
  } catch (error) {
    console.error(`could not record the alert: ${error?.message}`);
    return false;
  }
}
// For tests and shutdown: waits for webhook deliveries in flight.
export async function flushAlerts() {
  await Promise.all([...deliveries]);
}

// R1 (patch review v2): which install each Stripe subscription pays for,
// recorded when the subscription first attaches to a row. Payments and
// cancellations follow this, never an install id that may have changed
// hands since. null marks a subscription whose row was archived: its
// events are ignored.
function subscriptionIndex(store) {
  if (store.subscriptions == null) {
    store.subscriptions = {};
  }
  return store.subscriptions;
}

// Moves a row out of the way (kept under archived for support) and stops
// routing its subscriptions anywhere.
//
// Only an admin --force rebind archives a row that may still bill (a
// purchase never does, v5). A subscription of the archived row that was
// never cancelled keeps charging its customer while its events are ignored:
// that raises a DOUBLE-BILLING alert and is recorded in the archived entry
// for support to cancel by hand. Nothing here cancels that subscription.
function archiveRow(store, installId, reason) {
  const row = store.installs[installId];
  if (!row) {
    return;
  }
  const stillBilling = liveSubscriptions(row);
  for (const subscription of stillBilling) {
    raiseAlert(
      "DOUBLE-BILLING",
      `${installId}:${subscription}`,
      `DOUBLE-BILLING: archived install ${installId} still has active subscription ${subscription}; cancel it`,
      { install: installId, subscription },
    );
  }
  store.archived = Array.isArray(store.archived) ? store.archived : [];
  store.archived.push({
    install: installId,
    at: Math.floor(Date.now() / 1000),
    reason,
    still_billing: stillBilling,
    row,
  });
  const index = subscriptionIndex(store);
  for (const subscription of [...Object.keys(row.periods || {}), row.subscription]) {
    if (subscription && (index[subscription] === installId || index[subscription] === undefined)) {
      index[subscription] = null;
    }
  }
  delete store.installs[installId];
}

// N3, R1: moves a license to another install id, for a Mac that lost its
// install-id file. Admin only (node admin.js rebind), after confirming the
// customer by their Stripe email: there is no HTTP route, since install ids
// aren't secret. The old id is left with no row at all, and the license's
// subscriptions now route to the new id. A destination that has a license,
// or a row holding some Mac's secret, is refused unless force is set; then
// its row is archived. Returns the moved row, or a string naming why not.
export function rebindLicense(fromId, toId, { force = false } = {}) {
  if (!idPattern.test(fromId || "") || !idPattern.test(toId || "")) {
    return "install_id";
  }
  fromId = fromId.toLowerCase();
  toId = toId.toLowerCase();
  if (fromId === toId) {
    return "same install";
  }
  return withStore((store) => {
    const old = store.installs[fromId];
    if (
      !old ||
      old.revoked ||
      typeof old.until !== "string" ||
      !tokenBoundTo(old.token, fromId, old.until)
    ) {
      return "no license";
    }
    const target = store.installs[toId];
    if (target && (target.active || target.secret_hash || target.revoked) && !force) {
      return "destination has a license or a secret";
    }
    archiveRow(store, toId, "replaced by an admin rebind");
    const moved = { ...old, rebound_from: fromId, token: signRamp(toId, old.until) };
    store.installs[toId] = moved;
    delete store.installs[fromId];
    const index = subscriptionIndex(store);
    for (const subscription of [...Object.keys(moved.periods || {}), moved.subscription]) {
      if (subscription && (index[subscription] === fromId || index[subscription] === undefined)) {
        index[subscription] = toId;
      }
    }
    return moved;
  });
}

// A new random install secret: 64 hex characters, as the client makes.
function newSecret() {
  return randomBytes(32).toString("hex");
}

// R2: for a Mac that lost only its install-secret file. The row gets a new
// secret; only its hash is stored. The secret itself is returned once (in
// the result's secret field, never stored or logged) for support to pass to
// the customer, who enters it with "nightshift license secret --replace".
// Renewals of the row's subscriptions keep the new secret.
export function resetSecret(installId) {
  if (!idPattern.test(installId || "")) {
    return null;
  }
  return withStore((store) => {
    const row = store.installs[installId.toLowerCase()];
    if (!row) {
      return null;
    }
    const secret = newSecret();
    row.secret_hash = secretHash(secret);
    row.secret_source = "reset-secret";
    row.secret_at = new Date().toISOString();
    return { ...row, secret };
  });
}

export function revokeLicense(installId) {
  return withStore((store) => {
    const row = store.installs[installId];
    if (!row) {
      return null;
    }
    row.revoked = true;
    row.active = false;
    return row;
  });
}

// Finding 7: Stripe retries and reorders events. Each event id is handled
// once; ids are kept for kEventDays, longer than Stripe's 3-day retry window.
const kEventDays = 30;

export function eventSeen(eventId) {
  return Boolean(readStore().events?.[eventId]);
}

export function noteEvent(eventId) {
  return withStore((store) => {
    const now = Math.floor(Date.now() / 1000);
    const events = store.events || {};
    for (const [id, at] of Object.entries(events)) {
      if (typeof at !== "number" || now - at > kEventDays * 86400) {
        delete events[id];
      }
    }
    events[eventId] = now;
    store.events = events;
    return true;
  });
}

function invoiceInstall(invoice) {
  return (
    invoice.metadata?.install_id ||
    invoice.subscription_details?.metadata?.install_id ||
    invoice.parent?.subscription_details?.metadata?.install_id ||
    null
  );
}

function invoiceEnd(invoice) {
  return invoice.lines?.data?.[0]?.period?.end || invoice.period_end || null;
}

// Each subscription's paid-through day, keyed by subscription id ("" for a
// payment without one). Rows written before this kept a single
// subscription and until; those seed the map.
function periodsOf(row) {
  if (row.periods && typeof row.periods === "object" && !Array.isArray(row.periods)) {
    return row.periods;
  }
  const periods = {};
  if (typeof row.until === "string") {
    periods[typeof row.subscription === "string" ? row.subscription : ""] = row.until;
  }
  return periods;
}

// Points the row at its live subscription that runs longest: until, the
// subscription, active and a token bound to that day. A row with no live
// subscription is switched off and keeps its last day and token.
function settleRow(row, installId) {
  const canceled = Array.isArray(row.canceled) ? row.canceled : [];
  let best = null;
  for (const [subscription, until] of Object.entries(row.periods || {})) {
    if (typeof until !== "string" || (subscription && canceled.includes(subscription))) {
      continue;
    }
    if (best == null || until > best[1]) {
      best = [subscription, until];
    }
  }
  if (best == null) {
    row.active = false;
    return row;
  }
  row.until = best[1];
  if (best[0]) {
    row.subscription = best[0];
  }
  if (!tokenBoundTo(row.token, installId, row.until)) {
    row.token = signRamp(installId, row.until);
  }
  row.active = true;
  return row;
}

// Records a paid period (finding 7, N1). Each subscription's day only moves
// forward, a subscription that was deleted (or a revoked install) can't be
// switched back on by a late or replayed payment event, and the license
// follows whichever live subscription runs longest. A customer who cancels a
// yearly plan and then buys a monthly one gets the monthly's day, earlier
// or not, and a late event from the deleted plan can't take it away.
export async function rememberPaid(installId, untilUnix, details = {}) {
  if (!idPattern.test(installId || "") || !untilUnix) {
    return null;
  }
  const until = utcDate(untilUnix);
  const { subscription = null, customer = null, secret = null } = details;
  return withStore((store) => {
    const index = subscriptionIndex(store);
    let row;
    let firstAttach = false;
    if (subscription && Object.hasOwn(index, subscription)) {
      // R1: a subscription pays for the install it first attached to (or
      // was moved to by an admin rebind), whatever its metadata says now.
      if (index[subscription] == null) {
        return null;
      }
      installId = index[subscription];
      row = store.installs[installId];
      if (!row) {
        return null;
      }
    } else {
      row = store.installs[installId];
      // Rows from before the index already list their subscriptions.
      const known = Boolean(row && subscription && Object.hasOwn(periodsOf(row), subscription));
      // R1: a new purchase joins the install's row only when the buyer's
      // Mac holds that row's secret. Otherwise the row belongs to someone
      // else (or to a secret this Mac lost) and the buyer gets a fresh one.
      if (!known && !secret) {
        // Every license belongs to a Mac's secret; a purchase without one
        // (no client sends that) unlocks nothing.
        return null;
      }
      if (row && !known && !sameHash(secret, row.secret_hash)) {
        if (rowClaimed(row, installId)) {
          // v5 H1, v6 M1: the row is someone's. It is left exactly as it was; the
          // purchase is held, and settleHeld cancels and refunds it. (A Mac
          // that lost its secret gets a new one from support: reset-secret.)
          if (!subscription) {
            return null;
          }
          index[subscription] = null;
          const held = heldList(store);
          if (!held.some((entry) => entry.subscription === subscription)) {
            held.push({
              subscription,
              install: installId,
              // So the buyer's Mac can be told its purchase was refunded
              // (v5 L3). Kept in the store only, never in an alert.
              secret_hash: secret,
              customer,
              at: Math.floor(Date.now() / 1000),
              status: "pending",
            });
          }
          return { held: subscription };
        }
        // Nobody's: no secret, no active license and no live subscription.
        archiveRow(store, installId, "replaced by a purchase with another secret");
        row = undefined;
      }
      row = row || {};
      firstAttach = !known;
      if (subscription) {
        index[subscription] = installId;
      }
    }
    const canceled = Array.isArray(row.canceled) ? row.canceled : [];
    if (row.revoked || (subscription && canceled.includes(subscription))) {
      return null;
    }
    const periods = periodsOf(row);
    const key = subscription || "";
    const had = periods[key];
    const later = typeof had !== "string" || until > had;
    // Within one subscription, a payment that doesn't extend the period
    // can't switch a cancelled install back on: it is a replay or arrived
    // after the cancellation.
    if (!later && row.active === false) {
      return null;
    }
    if (later) {
      periods[key] = until;
    }
    row.periods = periods;
    settleRow(row, installId);
    if (customer && (later || !row.customer)) {
      row.customer = customer;
    }
    // Only a purchase records a secret; a renewal carries the one from its
    // checkout, which may be a secret the Mac has since lost (R2).
    if (firstAttach && secret && !row.secret_hash) {
      row.secret_hash = secret;
      row.secret_source = "purchase";
      row.secret_at = new Date().toISOString();
    }
    store.installs[installId] = row;
    return row;
  });
}

// A license granted by hand (N2: tokens issued outside Stripe get a row, so
// the client's refresh can hand them a bound token). The grant counts as a
// payment without a subscription; a later day replaces an earlier grant.
// Every grant makes a new secret, returned once in the result's secret field
// (never stored or logged) for support to pass on: a row's secret may be a
// squatter's (v5, M1). keepSecret keeps a row's secret (admin --keep-secret),
// once support knows whose it is; the result names its source and age.
export function grantLicense(installId, day, { keepSecret = false } = {}) {
  if (
    !idPattern.test(installId || "") ||
    !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(day || "") ||
    utcDate(Date.parse(`${day}T00:00:00Z`) / 1000) !== day
  ) {
    return null;
  }
  installId = installId.toLowerCase();
  return withStore((store) => {
    const row = store.installs[installId] || {};
    if (row.revoked) {
      return null;
    }
    let secret = null;
    const previous = row.secret_hash
      ? { source: row.secret_source || "unknown", at: row.secret_at || null }
      : null;
    if (!row.secret_hash || !keepSecret) {
      secret = newSecret();
      row.secret_hash = secretHash(secret);
      row.secret_source = "grant";
      row.secret_at = new Date().toISOString();
    }
    const periods = periodsOf(row);
    if (typeof periods[""] !== "string" || day > periods[""]) {
      periods[""] = day;
    }
    row.periods = periods;
    settleRow(row, installId);
    store.installs[installId] = row;
    return { ...row, ...(secret ? { secret } : {}), previous_secret: previous };
  });
}

// Finding 7: a deleted subscription is remembered, so a payment event for it
// that arrives later is ignored. The install stays active while another of
// its subscriptions is live, on that subscription's day.
export function rememberCanceled(installId, subscription) {
  if (!idPattern.test(installId || "")) {
    return null;
  }
  return withStore((store) => {
    const index = subscriptionIndex(store);
    let id = installId;
    if (subscription && Object.hasOwn(index, subscription)) {
      if (index[subscription] == null) {
        return null;
      }
      id = index[subscription];
    } else if (subscription) {
      // Never attached: a payment for it that arrives later is ignored.
      index[subscription] = null;
    }
    const row = store.installs[id];
    if (!row) {
      return null;
    }
    if (!subscription) {
      row.active = false;
      return row;
    }
    const canceled = Array.isArray(row.canceled) ? row.canceled : [];
    if (!canceled.includes(subscription)) {
      canceled.push(subscription);
    }
    row.canceled = canceled;
    row.periods = periodsOf(row);
    if (row.active === false) {
      return row;
    }
    return settleRow(row, id);
  });
}

function idOf(value) {
  return typeof value === "string" ? value : value?.id || null;
}

// Subscription states that must not unlock anything.
const deadStates = new Set(["canceled", "incomplete_expired", "unpaid"]);

async function subscriptionUntil(stripe, subscriptionId) {
  let subscription;
  try {
    subscription = await stripe.subscriptions.retrieve(subscriptionId);
  } catch (error) {
    // N7: a subscription Stripe no longer has (a deleted customer, test-mode
    // leftovers) is as good as cancelled. Failing would make Stripe retry
    // the event for days. Anything else (network, rate limit) still fails,
    // so a transient error is retried.
    if (error?.code === "resource_missing") {
      return { missing: true, dead: true };
    }
    throw error;
  }
  return {
    installId: subscription.metadata?.install_id || null,
    secret: subscription.metadata?.secret_hash || null,
    untilUnix: subscription.items?.data?.[0]?.current_period_end || null,
    customer: subscription.customer || null,
    dead: deadStates.has(subscription.status),
  };
}

// The payment behind an invoice, as refunds.create takes it. Older API
// versions put it on the invoice (payment_intent, charge); the pinned one
// (and basil onwards) only in its payments, which Stripe includes when
// asked to expand them.
function paymentOf(invoice) {
  if (!invoice || typeof invoice !== "object") {
    return null;
  }
  const paidPayment = (invoice.payments?.data || []).find(
    (entry) => !entry?.status || entry.status === "paid",
  )?.payment;
  const intent = idOf(invoice.payment_intent) || idOf(paidPayment?.payment_intent) || null;
  if (intent) {
    return { payment_intent: intent };
  }
  const charge = idOf(invoice.charge) || idOf(paidPayment?.charge);
  return charge ? { charge } : null;
}

// The subscription an invoice bills, in either API shape.
function invoiceSubscription(invoice) {
  return (
    idOf(invoice?.parent?.subscription_details?.subscription) ||
    idOf(invoice?.subscription) ||
    null
  );
}

// v8: the payment for a held subscription's invoice, asked of Stripe.
// The invoice id is one the server resolved itself (heldInvoice), never
// from metadata, and the invoice Stripe returns must bill that same
// subscription. The webhook's own copy of the invoice is not used: on
// current API versions it carries no payment at all.
async function paymentForInvoice(stripe, invoiceId, subscription) {
  if (!invoiceId) {
    return null;
  }
  const invoice = await stripe.invoices.retrieve(invoiceId, { expand: ["payments"] });
  if (!invoice || invoiceSubscription(invoice) !== subscription) {
    throw new Error("the held purchase's invoice doesn't bill its subscription");
  }
  let payment = paymentOf(invoice);
  if (!payment && stripe.invoicePayments?.list) {
    payment = paymentOf({ payments: await stripe.invoicePayments.list({ invoice: invoiceId }) });
  }
  return payment;
}

// v8: a held subscription's invoice, as the server resolves it: from the
// checkout session Stripe gave it for that subscription, from what it
// saved earlier, from Stripe's sessions for the subscription, or from the
// subscription's latest invoice.
async function heldInvoice(stripe, subscription, entry, session) {
  if (session && idOf(session.subscription) === subscription && idOf(session.invoice)) {
    return { invoiceId: idOf(session.invoice), sessionId: idOf(session) };
  }
  if (entry.invoice) {
    return { invoiceId: entry.invoice, sessionId: entry.session || null };
  }
  const found = (await stripe.checkout.sessions.list({ subscription, limit: 1 }))?.data?.[0];
  if (found && idOf(found.subscription) === subscription && idOf(found.invoice)) {
    return { invoiceId: idOf(found.invoice), sessionId: found.id };
  }
  const current = await stripe.subscriptions.retrieve(subscription);
  return { invoiceId: idOf(current?.latest_invoice), sessionId: found?.id || null };
}

function updateHeldEntry(subscription, fields) {
  return withStore((store) => {
    const entry = heldList(store).find((held) => held.subscription === subscription);
    if (entry) {
      Object.assign(entry, fields);
    }
    return entry || null;
  });
}

// Test hook: runs between a successful refund and marking it handled, so a
// test can play a crash there.
export const testHooks = { afterRefund: null };

// Whether a failed cancel failed because the subscription is already
// cancelled (or gone), as after a retry past the idempotency window.
async function alreadyCanceled(stripe, subscription, error) {
  if (error?.code === "resource_missing") {
    return true;
  }
  try {
    const current = await stripe.subscriptions.retrieve(subscription);
    return current?.status === "canceled" || current?.status === "incomplete_expired";
  } catch (lookup) {
    return lookup?.code === "resource_missing";
  }
}

// What a held buyer is told, on /success and by /license (v5 L3). v8:
// "refunded" only once the refund succeeded; until then it is pending.
const refundedMessage = "This purchase was refunded; contact support";
const pendingMessage = "This purchase is being reversed; contact support";
function heldReply(entry) {
  return entry?.status === "refunded"
    ? { error: "refunded", message: refundedMessage }
    : { error: "pending", message: pendingMessage };
}
function heldFor(installId, presented) {
  if (!presented) {
    return null;
  }
  return (
    heldList(readStore()).find(
      (entry) => entry.install === installId && sameHash(presented, entry.secret_hash),
    ) || null
  );
}

// v5: cancels a held purchase's own new subscription and refunds its
// payment. It touches only that subscription and that payment, never the
// install's row or its subscriptions. Stripe idempotency keys come from the
// checkout session (cancel-<session>, refund-<session>), so a retry after a
// crash at any point repeats nothing; the entry is marked refunded only once
// both succeeded. A failure leaves it held, raises an alert (once per
// session), and fails the webhook so Stripe retries it. v8: the payment is
// looked up from Stripe by the invoice the server resolved (heldInvoice,
// paymentForInvoice), on every path; the event's own copy isn't used.
async function settleHeld(stripe, subscription, { session = null } = {}) {
  const entry = heldEntry(subscription);
  if (!entry || entry.status === "refunded" || !stripe) {
    return null;
  }
  let sessionId = entry.session || null;
  let invoiceId = entry.invoice || null;
  let payment = entry.payment || null;
  let lookupError = null;
  try {
    const resolved = await heldInvoice(stripe, subscription, entry, session);
    sessionId = sessionId || resolved.sessionId;
    invoiceId = invoiceId || resolved.invoiceId;
    if (!payment) {
      payment = await paymentForInvoice(stripe, invoiceId, subscription);
    }
  } catch (error) {
    lookupError = error;
  }
  updateHeldEntry(subscription, { session: sessionId, invoice: invoiceId, payment });
  const key = sessionId || subscription;
  const details = {
    install: entry.install,
    subscription,
    customer: entry.customer || null,
    session: sessionId,
  };
  raiseAlert(
    "MISMATCHED-PURCHASE",
    key,
    `MISMATCHED-PURCHASE: install ${entry.install} is in use under another secret; ` +
      `session ${sessionId || "(unknown)"} subscription ${subscription} was held, ` +
      "and is being cancelled and refunded",
    details,
  );
  try {
    try {
      await stripe.subscriptions.cancel(subscription, {}, { idempotencyKey: `cancel-${key}` });
    } catch (error) {
      if (!(await alreadyCanceled(stripe, subscription, error))) {
        throw error;
      }
    }
    if (lookupError) {
      throw lookupError;
    }
    if (!payment) {
      throw new Error("no payment found to refund yet");
    }
    try {
      await stripe.refunds.create(payment, { idempotencyKey: `refund-${key}` });
    } catch (error) {
      // v5 L1: a retry after Stripe's 24-hour idempotency window finds the
      // work already done; that is success, not a stuck failure.
      if (error?.code !== "charge_already_refunded") {
        throw error;
      }
    }
  } catch (error) {
    updateHeldEntry(subscription, { status: "failed", failed_at: Math.floor(Date.now() / 1000) });
    raiseAlert(
      "REFUND-FAILED",
      key,
      `REFUND-FAILED: could not cancel and refund held session ${sessionId || "(unknown)"} ` +
        `subscription ${subscription}; do it by hand`,
      details,
    );
    throw error;
  }
  if (testHooks.afterRefund) {
    testHooks.afterRefund();
  }
  updateHeldEntry(subscription, {
    status: "refunded",
    handled_at: Math.floor(Date.now() / 1000),
  });
  return null;
}

export async function onInvoicePaid(invoice, stripe) {
  let installId = invoiceInstall(invoice);
  let untilUnix = invoiceEnd(invoice);
  let secret =
    invoice.metadata?.secret_hash ||
    invoice.subscription_details?.metadata?.secret_hash ||
    invoice.parent?.subscription_details?.metadata?.secret_hash ||
    null;
  const subscriptionId =
    idOf(invoice.parent?.subscription_details?.subscription) || idOf(invoice.subscription);
  if (subscriptionId && heldEntry(subscriptionId)) {
    return settleHeld(stripe, subscriptionId);
  }
  if (stripe && subscriptionId) {
    // The subscription's current state, not the event's snapshot, decides.
    const looked = await subscriptionUntil(stripe, subscriptionId);
    if (looked.missing && installId) {
      rememberCanceled(installId, subscriptionId);
    }
    if (looked.dead) {
      return null;
    }
    installId = installId || looked.installId;
    untilUnix = untilUnix || looked.untilUnix;
    secret = secret || looked.secret;
  }
  const result = await rememberPaid(installId, untilUnix, {
    subscription: subscriptionId,
    customer: idOf(invoice.customer),
    secret,
  });
  if (result?.held) {
    return settleHeld(stripe, result.held);
  }
  return result;
}

export async function onSessionCompleted(session, stripe) {
  if (session.payment_status !== "paid") {
    return null;
  }
  const installId = session.client_reference_id || session.metadata?.install_id;
  if (!idPattern.test(installId || "")) {
    return null;
  }
  const subscriptionId = idOf(session.subscription);
  if (!stripe || !subscriptionId) {
    return null;
  }
  noteSessionCompleted(session.id);
  if (heldEntry(subscriptionId)) {
    return settleHeld(stripe, subscriptionId, { session });
  }
  const looked = await subscriptionUntil(stripe, subscriptionId);
  if (looked.dead) {
    return null;
  }
  const result = await rememberPaid(installId, looked.untilUnix, {
    subscription: subscriptionId,
    customer: idOf(session.customer) || looked.customer,
    secret: session.metadata?.secret_hash || looked.secret,
  });
  if (result?.held) {
    return settleHeld(stripe, result.held, { session });
  }
  return result;
}

// v5, L1: /success hands out the token once per checkout session, and only
// within kSuccessSeconds of when this server first saw the session paid.
// After that the app gets it from /license, with its secret.
const kSuccessSeconds = 3600;
function noteSessionCompleted(sessionId) {
  if (typeof sessionId !== "string" || !sessionId) {
    return;
  }
  withStore((store) => {
    const sessions = (store.sessions ||= {});
    const now = Math.floor(Date.now() / 1000);
    for (const [id, seen] of Object.entries(sessions)) {
      if (now - (seen?.completed_at || 0) > kEventDays * 86400) {
        delete sessions[id];
      }
    }
    sessions[sessionId] ||= { completed_at: now };
  });
}
function takeSuccessDelivery(sessionId) {
  return withStore((store) => {
    const sessions = (store.sessions ||= {});
    const now = Math.floor(Date.now() / 1000);
    const seen = (sessions[sessionId] ||= { completed_at: now });
    if (seen.delivered_at || now - seen.completed_at > kSuccessSeconds) {
      return false;
    }
    seen.delivered_at = now;
    return true;
  });
}

// Finding 11: errors are logged here and answered with a generic body.
function failure(error) {
  if (error?.statusCode === 413) {
    return [413, "body too large"];
  }
  if (error instanceof StoreError) {
    return [503, "service unavailable"];
  }
  if (error?.type === "StripeSignatureVerificationError" || error instanceof SyntaxError) {
    return [400, "bad request"];
  }
  if (typeof error?.type === "string" && error.type.startsWith("Stripe")) {
    return [502, "payment service error"];
  }
  return [500, "internal error"];
}

function send(res, status, body, type, headers = {}) {
  const payload = body == null ? "" : typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": type || (body && typeof body !== "string" ? "application/json" : "text/plain"),
    "Content-Length": Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

function collect(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const fail = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      reject(error);
    };
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > 65536) {
        req.pause();
        fail(Object.assign(new Error("body too large"), { statusCode: 413 }));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on("error", fail);
  });
}

export function createApp(stripe = stripeClient()) {
  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url, publicBase());
      if (req.method === "POST" && url.pathname === "/checkout") {
        const body = JSON.parse((await collect(req)).toString("utf8") || "{}");
        if (!idPattern.test(body.install_id || "")) {
          send(res, 400, { error: "install_id" });
          return;
        }
        const presented = secretHash(req.headers["x-nightshift-secret"]);
        if (!presented) {
          send(res, 400, { error: "install secret" });
          return;
        }
        const stored = readStore().installs[body.install_id];
        const owned = Boolean(stored && sameHash(presented, stored.secret_hash));
        // v5 H1, v6 M1: an install whose row holds a secret (or is in use)
        // belongs to that secret. Anyone else is refused before any Stripe
        // call, with a reply that says nothing about it.
        if (stored && !owned && rowClaimed(stored, body.install_id)) {
          send(res, 409, { error: "contact support" });
          return;
        }
        const existing = owned ? licenseFor(body.install_id) : null;
        // v5 H1: an owned install with no license in force (lapsed, or after
        // reset-secret) buys again; its purchase attaches to its row.
        if (owned && existing) {
          // Finding 10: the install ID alone never opens the billing portal;
          // it takes the install's secret. A license with no Stripe customer
          // (a grant) gets the portal's email login link, if configured.
          let portalURL = process.env.STRIPE_PORTAL_LOGIN_URL || null;
          if (stripe && existing.customer) {
            try {
              const portal = await stripe.billingPortal.sessions.create({
                customer: existing.customer,
                return_url: `${publicBase()}/account`,
              });
              portalURL = portal.url;
            } catch (error) {
              console.error("billing portal:", error);
            }
          }
          send(res, 409, {
            error: "already licensed",
            until: existing.until,
            url: portalURL,
          });
          return;
        }
        if (!stripe || !process.env.STRIPE_PRICE_ID) {
          send(res, 503, { error: "checkout is not configured" });
          return;
        }
        const session = await stripe.checkout.sessions.create({
          mode: "subscription",
          client_reference_id: body.install_id,
          line_items: [{ price: process.env.STRIPE_PRICE_ID, quantity: 1 }],
          success_url: `${publicBase()}/success?session_id={CHECKOUT_SESSION_ID}`,
          cancel_url: `${publicBase()}/cancel`,
          subscription_data: {
            metadata: { install_id: body.install_id, secret_hash: presented },
          },
        });
        send(res, 200, { url: session.url });
        return;
      }

      // The license, only to the Mac holding the install's secret, sent in
      // a header with a POST (finding 10). There is no lookup by install id
      // alone, and no GET: install ids aren't secret.
      if (req.method === "POST" && url.pathname === "/license") {
        const installId =
          JSON.parse((await collect(req)).toString("utf8") || "{}").install_id || "";
        if (typeof installId !== "string" || !idPattern.test(installId)) {
          send(res, 400, "");
          return;
        }
        // Every reply, lapsed ones included, carries the signed server
        // time in a header: a 204 can't carry a body.
        const time = serverTimeToken(installId);
        const timed = time ? { "X-Nightshift-Time": time } : {};
        const presented = secretHash(req.headers["x-nightshift-secret"]);
        const stored = readStore().installs[installId];
        if (!presented || !stored || !sameHash(presented, stored.secret_hash)) {
          // Only the Mac whose purchase was held (it holds that secret) is
          // told; anyone else still gets a plain 204.
          const held = heldFor(installId, presented);
          if (held) {
            send(res, 409, heldReply(held), undefined, timed);
            return;
          }
          send(res, 204, "", undefined, timed);
          return;
        }
        if (stored.revoked) {
          send(res, 410, "", undefined, timed);
          return;
        }
        const row = licenseFor(installId);
        if (!row) {
          send(res, 204, "", undefined, timed);
          return;
        }
        send(res, 200, { token: row.token, until: row.until }, undefined, timed);
        return;
      }

      if (req.method === "GET" && url.pathname === "/success") {
        if (!stripe) {
          send(res, 503, "checkout is not configured");
          return;
        }
        const session = await stripe.checkout.sessions.retrieve(
          url.searchParams.get("session_id") || "",
        );
        if (session.payment_status !== "paid") {
          send(res, 402, "payment is not complete");
          return;
        }
        const paidSubscription = idOf(session.subscription);
        try {
          await onSessionCompleted(session, stripe);
        } catch (error) {
          // A held purchase whose refund is being retried is still answered.
          if (!(paidSubscription && heldEntry(paidSubscription))) {
            throw error;
          }
          console.error("GET /success: held purchase:", error?.message);
        }
        const heldNow = paidSubscription ? heldEntry(paidSubscription) : null;
        if (heldNow) {
          send(res, 409, heldReply(heldNow).message);
          return;
        }
        let row = idPattern.test(session.client_reference_id || "")
          ? licenseFor(session.client_reference_id)
          : null;
        // R1: only the license this checkout paid for.
        const paidFor = idOf(session.subscription);
        if (row && !(paidFor && Object.hasOwn(row.periods || {}, paidFor))) {
          row = null;
        }
        if (!row || !takeSuccessDelivery(session.id)) {
          send(res, 202, "payment received");
          return;
        }
        const token = encodeURIComponent(row.token);
        res.writeHead(302, { Location: `nightshift://license?token=${token}` });
        res.end();
        return;
      }

      if (req.method === "GET" && url.pathname === "/account") {
        send(res, 200, "You can close this window.");
        return;
      }

      if (req.method === "GET" && url.pathname === "/cancel") {
        send(res, 200, "Checkout canceled.");
        return;
      }

      if (req.method === "POST" && url.pathname === "/webhook") {
        const payload = await collect(req);
        const secret = process.env.STRIPE_WEBHOOK_SECRET;
        if (!secret) {
          send(res, 503, "webhook is not configured");
          return;
        }
        const hooks = stripe || new Stripe("sk_test_local", { apiVersion: stripeApiVersion });
        const event = hooks.webhooks.constructEvent(
          payload,
          req.headers["stripe-signature"],
          secret,
        );
        warnApiVersion(event.api_version);
        if (typeof event.id === "string" && eventSeen(event.id)) {
          send(res, 200, { received: true });
          return;
        }
        if (event.type === "invoice.paid") {
          await onInvoicePaid(event.data.object, stripe);
        } else if (
          event.type === "checkout.session.completed" &&
          event.data.object.payment_status === "paid"
        ) {
          await onSessionCompleted(event.data.object, stripe);
        } else if (event.type === "customer.subscription.deleted") {
          const installId = event.data.object.metadata?.install_id;
          rememberCanceled(installId, idOf(event.data.object.id));
        }
        // Recorded only once handled, so a failure is retried by Stripe.
        if (typeof event.id === "string") {
          noteEvent(event.id);
        }
        send(res, 200, { received: true });
        return;
      }

      send(res, 404, "");
    } catch (error) {
      const [status, message] = failure(error);
      if (status >= 500) {
        console.error(`${req.method} ${req.url?.split("?")[0]}:`, error);
      }
      send(res, status, { error: message });
      if (status === 413) {
        req.destroy();
      }
    }
  });
}

export function listen(port, stripe) {
  const server = createApp(stripe);
  server.listen(port, process.env.HOST || "127.0.0.1");
  return server;
}
