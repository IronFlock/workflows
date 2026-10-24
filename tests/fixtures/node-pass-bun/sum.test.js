import { expect, test } from "bun:test";
import { sum } from "./sum.js";

test("sum adds", () => expect(sum(2, 3)).toBe(5));
