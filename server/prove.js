import { spawn } from "node:child_process";
import { createHash, generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import Stripe from "stripe";
import { listen, licenseFor, saveLicense, signRamp, stripeApiVersion } from "./app.js";
import {
  checkoutSessionObject,
  eventObject,
  invoiceObject,
  subscriptionObject,
} from "./fixtures/stripe.js";

const repo = dirname(dirname(fileURLToPath(import.meta.url)));
const storeDir = mkdtempSync(join(tmpdir(), "nsstore-"));
process.env.NIGHTSHIFT_LICENSE_STORE = join(storeDir, "licenses.json");

// Finding 14: a throwaway key, never ~/.nightshift/license.pem. The client
// under test is the test-key build (make nightshift-testkey), which takes
// the public half from NIGHTSHIFT_TEST_PUBLIC_KEY; release builds ignore it.
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
process.env.NIGHTSHIFT_LICENSE_KEY = join(storeDir, "throwaway.pem");
writeFileSync(
  process.env.NIGHTSHIFT_LICENSE_KEY,
  privateKey.export({ type: "pkcs8", format: "pem" }),
  { mode: 0o600 },
);
process.env.NIGHTSHIFT_TEST_PUBLIC_KEY = publicKey
  .export({ type: "spki", format: "der" })
  .subarray(-32)
  .toString("hex");
const client = process.env.NIGHTSHIFT_PROVE_BIN || join(repo, "nightshift-testkey");

const secret = "whsec_nightshift_prove";
process.env.STRIPE_WEBHOOK_SECRET = secret;
delete process.env.STRIPE_SECRET_KEY;
delete process.env.STRIPE_PRICE_ID;

const stripe = new Stripe("sk_test_local", { apiVersion: stripeApiVersion });
const installId = "11111111-1111-4111-8111-111111111111";
const keptStore = process.env.NIGHTSHIFT_LICENSE_STORE;
const freshDir = mkdtempSync(join(tmpdir(), "nslock-"));
process.env.NIGHTSHIFT_LICENSE_STORE = join(freshDir, "missing", "licenses.json");
const fresh = saveLicense(installId, {
  active: true,
  token: signRamp(installId, "2099-01-01"),
  until: "2099-01-01",
});
if (!fresh || fresh.until !== "2099-01-01" || licenseFor(installId) == null) {
  throw new Error("fresh license store was not created");
}
process.env.NIGHTSHIFT_LICENSE_STORE = keptStore;
const firstEnd = Math.floor(Date.UTC(2027, 9, 1) / 1000);
const secondEnd = Math.floor(Date.UTC(2028, 9, 1) / 1000);

// The buying Mac's install secret: checkout stores its hash in the
// subscription metadata, and every license fetch presents it.
const macSecret = "a".repeat(64);
const macHash = createHash("sha256").update(macSecret).digest("hex");

// Stripe objects are built from the sandbox captures (fixtures/stripe.js).
function event(id, end) {
  return eventObject(
    id,
    "invoice.paid",
    invoiceObject(`in_${id}`, { metadata: { install_id: installId, secret_hash: macHash }, end }),
  );
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

// POST /license as the Mac makes it; there is no GET.
function fetchLicense(port, id = installId, presented = macSecret) {
  return fetch(`http://127.0.0.1:${port}/license`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Nightshift-Secret": presented },
    body: JSON.stringify({ install_id: id }),
  });
}

async function tokenFor(port) {
  const response = await fetchLicense(port);
  if (response.status !== 200) {
    throw new Error(`license ${response.status}`);
  }
  return response.json();
}

// Installs token in a fresh home whose install ID is id, as the Mac that
// bought it would have.
function install(token, id = installId) {
  const home = mkdtempSync(join(tmpdir(), "nightshift-license-"));
  const support = join(home, "Library", "Application Support", "nightshift");
  mkdirSync(support, { recursive: true, mode: 0o700 });
  writeFileSync(join(support, "install-id"), `${id}\n`, { mode: 0o600 });
  const child = spawn(client, ["license", token], {
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

const elsewhere = await install(first.token, "99999999-9999-4999-8999-999999999999").then(
  () => "accepted",
  (error) => error.message.trim(),
);
if (elsewhere !== "that license was rejected") {
  throw new Error(`token on another install: ${elsewhere}`);
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
  sub_return: { metadata: { install_id: returnId, secret_hash: macHash }, customer: "cus_return" },
  sub_invoice: { metadata: { install_id: invoiceId, secret_hash: macHash }, customer: "cus_invoice" },
};
const basil = {
  webhooks: stripe.webhooks,
  checkout: {
    sessions: {
      retrieve: async (id) =>
        checkoutSessionObject(id, {
          status: "complete",
          payment_status: id === "cs_unpaid" ? "unpaid" : "paid",
          client_reference_id: returnId,
          subscription: "sub_return",
          customer: "cus_return",
        }),
    },
  },
  subscriptions: {
    retrieve: async (id) =>
      subscriptionObject(id, {
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
await post(
  basilPort,
  eventObject(
    "evt_unpaid_session",
    "checkout.session.completed",
    checkoutSessionObject("cs_unpaid", {
      payment_status: "unpaid",
      status: "complete",
      client_reference_id: returnId,
      subscription: "sub_return",
    }),
  ),
);
const unpaidLicense = await fetchLicense(basilPort, returnId);
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
const returnText = await install(decodeURIComponent(location.slice(prefix.length)), returnId);
if (returnText !== "Ramp is unlocked through 2029-10-01") {
  throw new Error(`checkout return license ${returnText}`);
}

await post(
  basilPort,
  eventObject(
    "evt_parent",
    "invoice.paid",
    invoiceObject("in_parent", {
      subscription: "sub_invoice",
      metadata: { install_id: invoiceId, secret_hash: macHash },
      end: null,
    }),
  ),
);
const parentResponse = await fetchLicense(basilPort, invoiceId);
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
  secret_hash: macHash,
});
if (licenseFor(installId) != null) {
  throw new Error("expired license still counts");
}
const expiredLicense = await fetchLicense(basilPort);
if (expiredLicense.status !== 204) {
  throw new Error(`expired license ${expiredLicense.status}`);
}
const expiredCheckout = await fetch(`http://127.0.0.1:${basilPort}/checkout`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-Nightshift-Secret": macSecret },
  body: JSON.stringify({ install_id: installId }),
});
if (expiredCheckout.status === 409 || expiredCheckout.status === 400) {
  throw new Error(`expired checkout ${await expiredCheckout.text()}`);
}
process.env.NIGHTSHIFT_LICENSE_STORE = keptStore;

const corrupt = join(storeDir, "corrupt.json");
writeFileSync(corrupt, "{");
process.env.NIGHTSHIFT_LICENSE_STORE = corrupt;
const corruptLicense = await fetchLicense(basilPort);
const corruptText = await corruptLicense.text();
if (
  corruptLicense.status !== 503 ||
  !corruptText.includes("service unavailable") ||
  readFileSync(corrupt, "utf8") !== "{"
) {
  throw new Error(`corrupt store ${corruptLicense.status} ${corruptText}`);
}

basilServer.close();

// Review v2: the client never follows a redirect from the license server,
// so the X-Nightshift-Secret header can't be forwarded to another host.
// `nightshift license secret` POSTs /license with the secret; the server
// answers with a redirect to a second listener, which must never be reached.
async function redirectRefused(status) {
  let followed = 0;
  let forwardedSecret = false;
  const elsewhere = createServer((request, response) => {
    followed += 1;
    forwardedSecret ||= request.headers["x-nightshift-secret"] != null;
    response.writeHead(204);
    response.end();
  });
  elsewhere.listen(0, "127.0.0.1");
  await new Promise((resolve) => elsewhere.on("listening", resolve));
  let asked = 0;
  let presented = false;
  const redirecting = createServer((request, response) => {
    asked += 1;
    presented ||= request.headers["x-nightshift-secret"] === macSecret;
    request.resume();
    response.writeHead(status, {
      Location: `http://127.0.0.1:${elsewhere.address().port}/license`,
    });
    response.end();
  });
  redirecting.listen(0, "127.0.0.1");
  await new Promise((resolve) => redirecting.on("listening", resolve));

  const home = mkdtempSync(join(tmpdir(), "nightshift-redirect-"));
  const support = join(home, "Library", "Application Support", "nightshift");
  mkdirSync(support, { recursive: true, mode: 0o700 });
  writeFileSync(join(support, "install-id"), `${installId}\n`, { mode: 0o600 });
  writeFileSync(join(support, "server"), `http://127.0.0.1:${redirecting.address().port}\n`);
  const child = spawn(client, ["license", "secret"], {
    cwd: repo,
    env: { ...process.env, HOME: home, CFFIXED_USER_HOME: home },
  });
  child.stdout.resume();
  child.stderr.resume();
  child.stdin.end(`${macSecret}\n`);
  const code = await new Promise((resolve) => child.on("close", resolve));
  redirecting.close();
  elsewhere.close();
  if (asked !== 1 || !presented) {
    throw new Error(`redirect ${status}: the license server was asked ${asked} times`);
  }
  if (followed !== 0) {
    throw new Error(
      `redirect ${status} was followed${forwardedSecret ? " with the install secret" : ""}`,
    );
  }
  if (code === 0) {
    throw new Error(`redirect ${status} counted as a license`);
  }
}
for (const status of [301, 302, 303, 307, 308]) {
  await redirectRefused(status);
}

console.log(
  `unlocked through ${first.until}, renewed through ${second.until}, checkout return through ${parentLicense.until}, redirects refused`,
);
