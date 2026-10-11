// Stripe objects for the tests' fakes, built from responses captured in a
// Stripe sandbox at the server's pinned API version (stripeApiVersion in
// app.js) and scrubbed: stable fake ids, no keys, emails, names, client
// secrets or URLs. Each builder takes a captured object and sets only the
// fields a test cares about, so the fakes keep the real shapes: an invoice
// has no payment fields, and its payments come only through
// expand: ["payments"] or the invoice payments list.
import { readdirSync, readFileSync } from "node:fs";

export const fixtureApiVersion = "2026-03-25.dahlia";
const dir = new URL("./stripe-2026-03-25/", import.meta.url);

export function fixtureNames() {
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => name.slice(0, -".json".length));
}

export function fixture(name) {
  return JSON.parse(readFileSync(new URL(`${name}.json`, dir), "utf8"));
}

export function subscriptionObject(id, fields = {}) {
  const base = fixture("subscription");
  // The period is the test's to set; the captured one would leak in.
  const item = {
    ...base.items.data[0],
    current_period_start: null,
    current_period_end: null,
    ...(fields.items?.data?.[0] || {}),
  };
  return {
    ...base,
    status: "active",
    canceled_at: null,
    ended_at: null,
    cancel_at: null,
    latest_invoice: null,
    customer: null,
    metadata: {},
    ...fields,
    id,
    items: { ...base.items, data: [item] },
  };
}

// An invoice as retrieved or as sent in invoice.paid: no payment fields.
// With payments set, as retrieved with expand: ["payments"].
export function invoiceObject(
  id,
  { subscription = null, metadata = {}, customer = null, end, payments } = {},
) {
  const { payments: _captured, ...base } = fixture("invoice-expand-payments");
  const line = base.lines.data[0];
  const lines =
    end === null
      ? { ...base.lines, data: [], total_count: 0 }
      : {
          ...base.lines,
          data: [
            {
              ...line,
              invoice: id,
              metadata,
              period: { ...line.period, ...(end ? { end } : {}) },
              parent: {
                ...line.parent,
                subscription_item_details: {
                  ...line.parent.subscription_item_details,
                  subscription,
                },
              },
            },
          ],
        };
  const invoice = {
    ...base,
    id,
    customer,
    lines,
    period_end: end === null ? null : base.period_end,
    parent: { ...base.parent, subscription_details: { metadata, subscription } },
  };
  if (payments !== undefined) {
    invoice.payments = payments;
  }
  return invoice;
}

// The invoice's payments, as the list endpoint or the expanded field
// returns them.
export function invoicePaymentsList(invoiceId, paymentIntent) {
  const base = fixture("invoice-payments-list");
  const row = base.data[0];
  return {
    ...base,
    data: paymentIntent
      ? [{ ...row, invoice: invoiceId, payment: { type: "payment_intent", payment_intent: paymentIntent } }]
      : [],
  };
}

export function checkoutSessionObject(id, fields = {}) {
  return {
    ...fixture("checkout-session-complete"),
    client_reference_id: null,
    subscription: null,
    invoice: null,
    customer: null,
    metadata: {},
    ...fields,
    id,
  };
}

export function refundObject(id, { payment_intent = null, charge = null } = {}) {
  return { ...fixture("refund"), id, payment_intent, charge };
}

const eventFixtures = {
  "invoice.paid": "event-invoice-paid",
  "checkout.session.completed": "event-checkout-session-completed",
  "customer.subscription.deleted": "event-customer-subscription-deleted",
};
export function eventObject(id, type, object) {
  const base = fixture(eventFixtures[type]);
  return { ...base, id, type, data: { ...base.data, object } };
}
