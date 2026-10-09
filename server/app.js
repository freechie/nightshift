import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
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

export function stripeClient() {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) {
    return null;
  }
  const options = {};
  if (process.env.STRIPE_API_HOST) {
    options.host = process.env.STRIPE_API_HOST;
    options.port = Number(process.env.STRIPE_API_PORT || 12111);
    options.protocol = "http";
  }
  return new Stripe(key, options);
}

export function signRamp(day) {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(day)) {
    throw new Error("bad ramp date");
  }
  const payload = `ramp:${day}`;
  const file = join(tmpdir(), `nightshift-ramp-${process.pid}.txt`);
  try {
    writeFileSync(file, payload);
    const signed = spawnSync(
      "openssl",
      ["pkeyutl", "-sign", "-inkey", licenseKeyPath(), "-rawin", "-in", file],
    );
    if (signed.error) {
      throw signed.error;
    }
    const stderr = signed.stderr ? signed.stderr.toString() : "";
    if (signed.status !== 0) {
      throw new Error(stderr || "could not sign");
    }
    return `${Buffer.from(payload).toString("base64")}.${signed.stdout.toString("base64")}`;
  } finally {
    rmSync(file, { force: true });
  }
}

export function utcDate(unix) {
  const date = new Date(unix * 1000);
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${date.getUTCFullYear()}-${month}-${day}`;
}

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
    throw new Error("license store is unreadable");
  }
  if (
    store == null ||
    typeof store !== "object" ||
    Array.isArray(store) ||
    store.installs == null ||
    typeof store.installs !== "object" ||
    Array.isArray(store.installs)
  ) {
    throw new Error("license store is unreadable");
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
        throw new Error("license store is locked");
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

export function licenseFor(installId) {
  const row = readStore().installs[installId];
  if (!row || !row.active || !row.token) {
    return null;
  }
  if (typeof row.until === "string" && row.until < utcToday()) {
    return null;
  }
  return row;
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

export async function rememberPaid(installId, untilUnix) {
  if (!idPattern.test(installId || "") || !untilUnix) {
    return null;
  }
  const until = utcDate(untilUnix);
  const token = signRamp(until);
  return saveLicense(installId, { token, until, active: true });
}

async function subscriptionUntil(stripe, subscriptionId) {
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  return {
    installId: subscription.metadata?.install_id || null,
    untilUnix: subscription.items?.data?.[0]?.current_period_end || null,
    customer: subscription.customer || null,
  };
}

export async function onInvoicePaid(invoice, stripe) {
  let installId = invoiceInstall(invoice);
  let untilUnix = invoiceEnd(invoice);
  const parent = invoice.parent?.subscription_details?.subscription;
  if ((!installId || !untilUnix) && stripe && parent) {
    const subscriptionId = typeof parent === "string" ? parent : parent.id;
    const looked = await subscriptionUntil(stripe, subscriptionId);
    installId = installId || looked.installId;
    untilUnix = untilUnix || looked.untilUnix;
  }
  const saved = await rememberPaid(installId, untilUnix);
  if (saved && invoice.customer) {
    saveLicense(installId, { customer: invoice.customer });
  }
  return saved;
}

export async function onSessionCompleted(session, stripe) {
  if (session.payment_status !== "paid") {
    return null;
  }
  const installId = session.client_reference_id || session.metadata?.install_id;
  if (!idPattern.test(installId || "")) {
    return null;
  }
  const subscriptionId =
    typeof session.subscription === "string"
      ? session.subscription
      : session.subscription?.id;
  if (!stripe || !subscriptionId) {
    return null;
  }
  const looked = await subscriptionUntil(stripe, subscriptionId);
  const saved = await rememberPaid(installId, looked.untilUnix);
  if (saved && session.customer) {
    saveLicense(installId, { customer: session.customer });
  }
  return saved;
}

function send(res, status, body, type) {
  const payload = body == null ? "" : typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": type || (body && typeof body !== "string" ? "application/json" : "text/plain"),
    "Content-Length": Buffer.byteLength(payload),
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
        const existing = licenseFor(body.install_id);
        if (existing) {
          let portalURL = null;
          if (stripe && existing.customer) {
            try {
              const portal = await stripe.billingPortal.sessions.create({
                customer: existing.customer,
                return_url: `${publicBase()}/account`,
              });
              portalURL = portal.url;
            } catch {
              portalURL = null;
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
          subscription_data: { metadata: { install_id: body.install_id } },
        });
        send(res, 200, { url: session.url });
        return;
      }

      if (req.method === "GET" && url.pathname === "/license") {
        const installId = url.searchParams.get("install_id") || "";
        if (!idPattern.test(installId)) {
          send(res, 400, "");
          return;
        }
        const row = licenseFor(installId);
        if (!row) {
          send(res, 204, "");
          return;
        }
        send(res, 200, { token: row.token, until: row.until });
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
        await onSessionCompleted(session, stripe);
        const row = licenseFor(session.client_reference_id || "");
        if (!row) {
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
        const hooks = stripe || new Stripe("sk_test_local");
        const event = hooks.webhooks.constructEvent(
          payload,
          req.headers["stripe-signature"],
          secret,
        );
        if (event.type === "invoice.paid") {
          await onInvoicePaid(event.data.object, stripe);
        } else if (
          event.type === "checkout.session.completed" &&
          event.data.object.payment_status === "paid"
        ) {
          await onSessionCompleted(event.data.object, stripe);
        } else if (event.type === "customer.subscription.deleted") {
          const installId = event.data.object.metadata?.install_id;
          if (idPattern.test(installId || "")) {
            saveLicense(installId, { active: false });
          }
        }
        send(res, 200, { received: true });
        return;
      }

      send(res, 404, "");
    } catch (error) {
      if (error.statusCode === 413) {
        send(res, 413, { error: "body too large" });
        req.destroy();
        return;
      }
      const message = error.message || "bad request";
      const storeDown =
        message === "license store is unreadable" || message === "license store is locked";
      send(res, storeDown ? 503 : 400, { error: message });
    }
  });
}

export function listen(port, stripe) {
  const server = createApp(stripe);
  server.listen(port, process.env.HOST || "127.0.0.1");
  return server;
}
