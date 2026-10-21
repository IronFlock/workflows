// Planted for the harness self-test: logs a secret-looking environment value.
export function debugBilling() {
  console.log("billing config", process.env.STRIPE_SECRET);
}
