import { test } from "node:test";
import assert from "node:assert/strict";
import { sum } from "./sum.js";

test("sum adds", () => assert.equal(sum(2, 3), 5));

// Planted: a failing test the gate must catch.
test("planted failure", () => assert.equal(sum(2, 2), 5));
