import { writeFileSync } from "node:fs";
import Stripe from "stripe";
import { envPath, loadEnv } from "./app.js";

function writeEnv(values) {
  const lines = Object.entries(values).map(([key, value]) => `${key}=${value}`);
  writeFileSync(envPath, `${lines.join("\n")}\n`, { mode: 0o600 });
}

loadEnv();
const key = process.env.STRIPE_SECRET_KEY;
if (!key) {
  console.error("Set STRIPE_SECRET_KEY to a test secret key, then re-run.");
  process.exit(1);
}

const stripeOptions = {};
if (process.env.STRIPE_API_HOST) {
  stripeOptions.host = process.env.STRIPE_API_HOST;
  stripeOptions.port = Number(process.env.STRIPE_API_PORT || 12111);
  stripeOptions.protocol = "http";
}
const stripe = new Stripe(key, stripeOptions);
const cents = Number(process.env.STRIPE_ANNUAL_CENTS || 2000);
const base = (process.env.PUBLIC_BASE_URL || "http://127.0.0.1:8787").replace(
  /\/$/,
  "",
);

let product = null;
for await (const item of stripe.products.list({ limit: 100, active: true })) {
  if (item.metadata?.nightshift === "ramp") {
    product = item;
    break;
  }
}
if (!product) {
  product = await stripe.products.create({
    name: "Nightshift ramp",
    metadata: { nightshift: "ramp" },
  });
}

let price = null;
const prices = await stripe.prices.list({
  product: product.id,
  active: true,
  limit: 100,
});
price = prices.data.find(
  (item) => item.recurring?.interval === "year" && item.unit_amount === cents,
);
if (!price) {
  price = await stripe.prices.create({
    product: product.id,
    currency: "usd",
    unit_amount: cents,
    recurring: { interval: "year" },
  });
}

const portal = await stripe.billingPortal.configurations.create({
  business_profile: { headline: "Nightshift ramp" },
  features: {
    payment_method_update: { enabled: true },
    subscription_cancel: { enabled: true, mode: "at_period_end" },
  },
});

let webhookSecret = process.env.STRIPE_WEBHOOK_SECRET || "";
if (base.startsWith("https://")) {
  const endpoint = await stripe.webhookEndpoints.create({
    url: `${base}/webhook`,
    enabled_events: [
      "invoice.paid",
      "checkout.session.completed",
      "customer.subscription.deleted",
    ],
  });
  webhookSecret = endpoint.secret || webhookSecret;
}

writeEnv({
  STRIPE_SECRET_KEY: key,
  STRIPE_WEBHOOK_SECRET: webhookSecret,
  STRIPE_PRICE_ID: price.id,
  STRIPE_ANNUAL_CENTS: String(cents),
  PUBLIC_BASE_URL: base,
  NIGHTSHIFT_LICENSE_KEY: process.env.NIGHTSHIFT_LICENSE_KEY || "",
  PORT: process.env.PORT || "8787",
});

console.log(`product ${product.id}`);
console.log(`price ${price.id} ${cents} cents per year`);
console.log(`portal ${portal.id}`);
if (!base.startsWith("https://")) {
  console.log(
    "Local webhook: stripe listen --forward-to localhost:8787/webhook",
  );
}
