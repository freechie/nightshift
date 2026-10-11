// Support tasks that change the license store by hand. Run on the server;
// there is no HTTP route to any of them.
//   node admin.js grant [--keep-secret] <install-id> <YYYY-MM-DD>
//       a license outside Stripe, with a new install secret printed once
//       (see below). A row's existing secret may be a squatter's, so it is
//       replaced unless --keep-secret is given; either way its source and
//       age are printed.
//   node admin.js rebind [--force] <old-install-id> <new-install-id>
//       move a license to a Mac's new install id (its install-id file was
//       lost), once the customer is confirmed by their Stripe email. Nothing
//       is left at the old id. A new id that already has a license or a
//       Mac's secret is refused; --force archives that row first.
//   node admin.js reset-secret <install-id>
//       for a Mac that lost only its install-secret file: a new secret,
//       printed once (see below)
//   node admin.js revoke <install-id>
//   node admin.js alerts
//       list the alerts in server/data/alerts.jsonl (see below)
// The customer's Mac prints its install id with: nightshift license id
//
// A new install secret is printed to stdout only, once, and nowhere else:
// the store keeps only its SHA-256, and nothing here logs it. Pass it to the
// customer privately; they enter it with
//   nightshift license secret          (or --replace, after reset-secret)
// which reads it from the keyboard or a pipe, never the command line.
//
// Alerts for support, in server/data/alerts.jsonl (POSTed to
// SUPPORT_ALERT_WEBHOOK_URL too, when set), one per session or subscription:
//   DOUBLE-BILLING: a row archived by rebind --force still has a live
//     subscription; cancel it in Stripe by hand.
//   MISMATCHED-PURCHASE: someone paid with another secret for an install in
//     use. That purchase (only its own new subscription and payment) is
//     cancelled and refunded automatically; the install is untouched.
//   REFUND-FAILED: that cancel or refund failed (Stripe retries the event);
//     if it persists, cancel and refund the named session by hand.
import {
  alertsFile,
  grantLicense,
  listAlerts,
  loadEnv,
  rebindLicense,
  resetSecret,
  revokeLicense,
} from "./app.js";

loadEnv();
const args = process.argv.slice(2);
const command = args.shift();
const force = command === "rebind" && args[0] === "--force";
if (force) {
  args.shift();
}
const keepSecret = command === "grant" && args[0] === "--keep-secret";
if (keepSecret) {
  args.shift();
}
if (command === "alerts" && args.length === 0) {
  const alerts = listAlerts();
  for (const alert of alerts) {
    console.log(`${alert.at} ${alert.message}`);
  }
  console.log(`${alerts.length} alert${alerts.length === 1 ? "" : "s"} in ${alertsFile()}`);
  process.exit(0);
}
const [first, second] = args;
let result = null;
let target = first?.toLowerCase();
if (command === "grant" && first && second && args.length === 2) {
  result = grantLicense(first, second, { keepSecret });
} else if (command === "rebind" && first && second && args.length === 2) {
  result = rebindLicense(first, second, { force });
  target = second.toLowerCase();
} else if (command === "reset-secret" && first && args.length === 1) {
  result = resetSecret(first);
} else if (command === "revoke" && first && args.length === 1) {
  result = revokeLicense(first.toLowerCase());
} else {
  console.error(
    "usage: node admin.js grant [--keep-secret] <install-id> <YYYY-MM-DD> |" +
      " rebind [--force] <old-id> <new-id> | reset-secret <install-id> | revoke <install-id> | alerts",
  );
  process.exit(2);
}
if (result == null || typeof result === "string") {
  console.error(`${command} failed: ${result || "no such install, or a bad id or date"}`);
  process.exit(1);
}
const state = result.until
  ? `licensed through ${result.until}${result.active ? "" : " (inactive)"}`
  : "no license";
console.log(`${command} ok: install ${target}, ${state}`);
if (command === "grant" && result.previous_secret) {
  const { source, at } = result.previous_secret;
  console.log(
    `${typeof result.secret === "string" ? "replaced" : "kept"} the install's secret ` +
      `(from ${source}${at ? `, set ${at}` : ""})`,
  );
}
if (typeof result.secret === "string") {
  process.stdout.write(`install secret (shown once): ${result.secret}\n`);
}
