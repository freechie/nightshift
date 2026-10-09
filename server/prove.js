import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Stripe from "stripe";
import { listen, licenseFor, saveLicense } from "./app.js";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const storeDir = mkdtempSync(join(tmpdir(), "nsstore-"));
process.env.NIGHTSHIFT_LICENSE_STORE = join(storeDir, "licenses.json");

const secret = "whsec_nightshift_prove";
process.env.STRIPE_WEBHOOK_SECRET = secret;
delete process.env.STRIPE_SECRET_KEY;
delete process.env.STRIPE_PRICE_ID;

const stripe = new Stripe("sk_test_local");
const installId = "11111111-1111-4111-8111-111111111111";
const keptStore = process.env.NIGHTSHIFT_LICENSE_STORE;
const freshDir = mkdtempSync(join(tmpdir(), "nslock-"));
process.env.NIGHTSHIFT_LICENSE_STORE = join(freshDir, "missing", "licenses.json");
const fresh = saveLicense(installId, {
  active: true,
  token: "fresh-token",
  until: "2099-01-01",
});
if (!fresh || fresh.until !== "2099-01-01" || licenseFor(installId) == null) {
  throw new Error("fresh license store was not created");
}
process.env.NIGHTSHIFT_LICENSE_STORE = keptStore;
const firstEnd = Math.floor(Date.UTC(2027, 9, 1) / 1000);
const secondEnd = Math.floor(Date.UTC(2028, 9, 1) / 1000);

function event(id, end) {
  return {
    id,
    object: "event",
    type: "invoice.paid",
    data: {
      object: {
        id: `in_${id}`,
        object: "invoice",
        metadata: { install_id: installId },
        lines: { data: [{ period: { end } }] },
      },
    },
  };
}

async function post(port, body) {
  const payload = JSON.stringify(body);
  const header = stripe.webhooks.generateTestHeaderString({
    payload,
    secret,
  });
  const response = await fetch(`http://127.0.0.1:${port}/webhook`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Stripe-Signature": header,
    },
    body: payload,
  });
  if (!response.ok) {
    throw new Error(`webhook ${response.status} ${await response.text()}`);
  }
}

async function tokenFor(port) {
  const response = await fetch(
    `http://127.0.0.1:${port}/license?install_id=${installId}`,
  );
  if (response.status !== 200) {
    throw new Error(`license ${response.status}`);
  }
  return response.json();
}

function install(token) {
  const home = mkdtempSync(join(tmpdir(), "nightshift-license-"));
  const child = spawn(join(repo, "nightshift"), ["license", token], {
    cwd: repo,
    env: { ...process.env, HOME: home, CFFIXED_USER_HOME: home },
  });
  let out = "";
  let err = "";
  child.stdout.on("data", (chunk) => {
    out += chunk;
  });
  child.stderr.on("data", (chunk) => {
    err += chunk;
  });
  return new Promise((resolve, reject) => {
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(err || out || `exit ${code}`));
        return;
      }
      resolve(out.trim());
    });
  });
}

const server = listen(0);
await new Promise((resolve) => server.on("listening", resolve));
const port = server.address().port;

await post(port, event("evt_year_1", firstEnd));
const first = await tokenFor(port);
const firstText = await install(first.token);
if (first.until !== "2027-10-01" || firstText !== "Ramp is unlocked through 2027-10-01") {
  throw new Error(`first license ${first.until} ${firstText}`);
}

await post(port, event("evt_year_2", secondEnd));
const second = await tokenFor(port);
const secondText = await install(second.token);
if (second.until !== "2028-10-01" || secondText !== "Ramp is unlocked through 2028-10-01") {
  throw new Error(`renewed license ${second.until} ${secondText}`);
}
if (second.until <= first.until) {
  throw new Error("renewal did not extend the date");
}

server.close();

const basilEnd = Math.floor(Date.UTC(2029, 9, 1) / 1000);
const returnId = "22222222-2222-4222-8222-222222222222";
const invoiceId = "33333333-3333-4333-8333-333333333333";
const subscriptions = {
  sub_return: { metadata: { install_id: returnId }, customer: "cus_return" },
  sub_invoice: { metadata: { install_id: invoiceId }, customer: "cus_invoice" },
};
const basil = {
  webhooks: stripe.webhooks,
  checkout: {
    sessions: {
      retrieve: async (id) => ({
        id,
        status: "complete",
        payment_status: id === "cs_unpaid" ? "unpaid" : "paid",
        client_reference_id: returnId,
        subscription: "sub_return",
        customer: "cus_return",
      }),
    },
  },
  subscriptions: {
    retrieve: async (id) => ({
      id,
      ...subscriptions[id],
      items: { data: [{ current_period_end: basilEnd }] },
    }),
  },
};

const basilServer = listen(0, basil);
await new Promise((resolve) => basilServer.on("listening", resolve));
const basilPort = basilServer.address().port;

const unpaid = await fetch(
  `http://127.0.0.1:${basilPort}/success?session_id=cs_unpaid`,
  { redirect: "manual" },
);
if (unpaid.status !== 402) {
  throw new Error(`unpaid checkout ${unpaid.status} ${await unpaid.text()}`);
}
await post(basilPort, {
  id: "evt_unpaid_session",
  object: "event",
  type: "checkout.session.completed",
  data: {
    object: {
      id: "cs_unpaid",
      object: "checkout.session",
      payment_status: "unpaid",
      status: "complete",
      client_reference_id: returnId,
      subscription: "sub_return",
    },
  },
});
const unpaidLicense = await fetch(
  `http://127.0.0.1:${basilPort}/license?install_id=${returnId}`,
);
if (unpaidLicense.status !== 204) {
  throw new Error(`unpaid license ${unpaidLicense.status}`);
}

const returned = await fetch(
  `http://127.0.0.1:${basilPort}/success?session_id=cs_return`,
  { redirect: "manual" },
);
const location = returned.headers.get("location") || "";
const prefix = "nightshift://license?token=";
if (returned.status !== 302 || !location.startsWith(prefix)) {
  throw new Error(`checkout return ${returned.status} ${location}`);
}
const returnText = await install(decodeURIComponent(location.slice(prefix.length)));
if (returnText !== "Ramp is unlocked through 2029-10-01") {
  throw new Error(`checkout return license ${returnText}`);
}

await post(basilPort, {
  id: "evt_parent",
  object: "event",
  type: "invoice.paid",
  data: {
    object: {
      id: "in_parent",
      object: "invoice",
      parent: {
        type: "subscription_details",
        subscription_details: {
          subscription: "sub_invoice",
          metadata: { install_id: invoiceId },
        },
      },
    },
  },
});
const parentResponse = await fetch(
  `http://127.0.0.1:${basilPort}/license?install_id=${invoiceId}`,
);
const parentLicense = parentResponse.status === 200 ? await parentResponse.json() : {};
if (parentLicense.until !== "2029-10-01") {
  throw new Error(`invoice without a line period ${parentResponse.status}`);
}

const account = await fetch(`http://127.0.0.1:${basilPort}/account`);
const accountText = await account.text();
if (account.status !== 200 || accountText !== "You can close this window.") {
  throw new Error(`account page ${account.status} ${accountText}`);
}

const expiredStore = join(storeDir, "expired.json");
process.env.NIGHTSHIFT_LICENSE_STORE = expiredStore;
saveLicense(installId, {
  active: true,
  token: "expired-token",
  until: "2020-01-01",
});
if (licenseFor(installId) != null) {
  throw new Error("expired license still counts");
}
const expiredLicense = await fetch(
  `http://127.0.0.1:${basilPort}/license?install_id=${installId}`,
);
if (expiredLicense.status !== 204) {
  throw new Error(`expired license ${expiredLicense.status}`);
}
const expiredCheckout = await fetch(`http://127.0.0.1:${basilPort}/checkout`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ install_id: installId }),
});
if (expiredCheckout.status === 409) {
  throw new Error(`expired checkout ${await expiredCheckout.text()}`);
}
process.env.NIGHTSHIFT_LICENSE_STORE = keptStore;

const corrupt = join(storeDir, "corrupt.json");
writeFileSync(corrupt, "{");
process.env.NIGHTSHIFT_LICENSE_STORE = corrupt;
const corruptLicense = await fetch(
  `http://127.0.0.1:${basilPort}/license?install_id=${installId}`,
);
const corruptText = await corruptLicense.text();
if (
  corruptLicense.status !== 503 ||
  !corruptText.includes("license store is unreadable") ||
  readFileSync(corrupt, "utf8") !== "{"
) {
  throw new Error(`corrupt store ${corruptLicense.status} ${corruptText}`);
}

basilServer.close();
console.log(
  `unlocked through ${first.until}, renewed through ${second.until}, checkout return through ${parentLicense.until}`,
);
