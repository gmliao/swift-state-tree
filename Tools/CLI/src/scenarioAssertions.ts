export type ScenarioAssert = {
  path: string;
  equals?: unknown;
  exists?: boolean;
  greaterThanOrEqual?: number;
  message?: string;
};

export type AssertionResult = {
  value: unknown;
  normalizedValue: unknown;
  normalizedEquals: unknown;
};

export function getNestedValue(obj: any, path: string): any {
  if (!path) return obj;
  return path.split(".").reduce((o, i) => (o ? o[i] : undefined), obj);
}

export function deepEqual(a: any, b: any): boolean {
  if (a === b) return true;

  if (a === null || b === null) return a === b;
  if (typeof a !== typeof b) return false;

  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i += 1) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }

  if (typeof a === "object" && typeof b === "object") {
    const keysA = Object.keys(a);
    const keysB = Object.keys(b);
    if (keysA.length !== keysB.length) return false;
    for (const key of keysA) {
      if (!keysB.includes(key)) return false;
      if (!deepEqual(a[key], b[key])) return false;
    }
    return true;
  }

  return false;
}

export function normalizeForCompare(value: any): any {
  if (value === null || value === undefined) return value;

  if (Array.isArray(value)) {
    return value.map((item) => normalizeForCompare(item));
  }

  if (typeof value === "object") {
    if (typeof (value as any).toJSON === "function") {
      return normalizeForCompare((value as any).toJSON());
    }

    const result: any = {};
    for (const [key, val] of Object.entries(value)) {
      result[key] = normalizeForCompare(val);
    }
    return result;
  }

  return value;
}

export function evaluateAssertion(
  state: unknown,
  assert: ScenarioAssert,
): AssertionResult {
  const { path, equals, exists, greaterThanOrEqual, message } = assert;
  const value = getNestedValue(state, path);
  const normalizedValue = normalizeForCompare(value);
  const normalizedEquals = normalizeForCompare(equals);

  if (exists !== undefined) {
    const isPresent = value !== undefined;
    if (isPresent !== exists) {
      throw new Error(
        message ||
          `Assertion failed: path ${path} presence should be ${exists}, but got ${isPresent} (value: ${JSON.stringify(value)})`,
      );
    }
  }

  if (equals !== undefined) {
    if (!deepEqual(normalizedValue, normalizedEquals)) {
      throw new Error(
        message ||
          `Assertion failed: ${path} expected ${JSON.stringify(equals)}, but got ${JSON.stringify(value)} (type: ${typeof value})`,
      );
    }
  }

  if (greaterThanOrEqual !== undefined) {
    const numValue = typeof value === "number" ? value : Number(value);
    const numExpected =
      typeof greaterThanOrEqual === "number"
        ? greaterThanOrEqual
        : Number(greaterThanOrEqual);
    if (isNaN(numValue) || isNaN(numExpected) || numValue < numExpected) {
      throw new Error(
        message ||
          `Assertion failed: ${path} expected >= ${greaterThanOrEqual}, but got ${value}`,
      );
    }
  }

  return { value, normalizedValue, normalizedEquals };
}
