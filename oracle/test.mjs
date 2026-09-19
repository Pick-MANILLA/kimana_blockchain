// Unit tests for the oracle's integer-only rate handling: node --test oracle/test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { toScaled8, deviationBps, extractRateText } from "./index.mjs";

test("toScaled8 scales without floats", () => {
  assert.equal(toScaled8("1645.25"), 164_525_000_000n);
  assert.equal(toScaled8("1645"), 164_500_000_000n);
  assert.equal(toScaled8("0.00000001"), 1n);
  assert.equal(toScaled8("  12.10  "), 1_210_000_000n);
});

test("toScaled8 truncates rather than rounding, like the contract", () => {
  assert.equal(toScaled8("1.123456789"), 112_345_678n);
  assert.equal(toScaled8("1.999999999"), 199_999_999n);
});

test("toScaled8 is exact where the obvious float version is not", () => {
  const text = "1645.2512345678901234";
  // Truncated at 8 decimals, the only correct answer is 1645.25123456.
  assert.equal(toScaled8(text), 164_525_123_456n);
  // Going through a JS number instead rounds the last digit up, and the on-chain reference would then
  // disagree with the backend's own integer maths by one unit.
  const viaFloat = BigInt(Math.round(Number(text) * 1e8));
  assert.equal(viaFloat, 164_525_123_457n);
  assert.notEqual(viaFloat, toScaled8(text));
});

test("toScaled8 rejects rubbish", () => {
  for (const bad of ["", "abc", "1.2.3", "-5", "1e8", "NaN"]) {
    assert.throws(() => toScaled8(bad), /not a decimal number/);
  }
});

test("deviationBps rounds up, mirroring FxMath", () => {
  assert.equal(deviationBps(100n, 100n), 0n);
  assert.equal(deviationBps(101n, 100n), 100n); // 1%
  assert.equal(deviationBps(99n, 100n), 100n);
  assert.equal(deviationBps(10_001n, 10_000n), 1n);
  assert.equal(deviationBps(100_001n, 100_000n), 1n); // rounds up from 0.1
  assert.equal(deviationBps(5n, 0n), 10_000n);
});

test("extractRateText reads the number as text", () => {
  const body = '{"result":"success","base":"USD","rates":{"GHS":12.10,"NGN":1645.2512345678901234,"EUR":0.92}}';
  assert.equal(extractRateText(body, "NGN"), "1645.2512345678901234");
  assert.equal(extractRateText(body, "GHS"), "12.10");
  assert.throws(() => extractRateText(body, "XOF"), /no rate for XOF/);
});

test("extractRateText also handles the frankfurter shape", () => {
  const body = '{"amount":1.0,"base":"USD","date":"2026-09-19","rates":{"NGN": 1645.25}}';
  assert.equal(extractRateText(body, "NGN"), "1645.25");
});
