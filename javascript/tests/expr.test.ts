import { describe, it, expect } from "vitest";
import { evaluateExpression, validateExpression } from "../src/expr.js";
import { ExpressionError } from "../src/errors.js";

describe("validateExpression", () => {
  it("accepts simple arithmetic", () => {
    expect(() => validateExpression("input_tokens * 2 + output_tokens")).not.toThrow();
  });

  it("accepts expressions with allowed functions", () => {
    expect(() => validateExpression("ceil(input_tokens * 0.001)")).not.toThrow();
    expect(() => validateExpression("floor(output_tokens / 1000)")).not.toThrow();
    expect(() => validateExpression("min(input_tokens, output_tokens) * 0.5")).not.toThrow();
    expect(() => validateExpression("max(0, tool_calls - 5) * 2")).not.toThrow();
    expect(() => validateExpression("round(input_tokens * 0.001)")).not.toThrow();
  });

  it("accepts ternary expressions (X if cond else Y)", () => {
    expect(() => validateExpression("output_tokens * 0.5 if output_tokens > 1000 else output_tokens * 0.3")).not.toThrow();
  });

  it("accepts boolean operators", () => {
    expect(() => validateExpression("5 if (tool_calls > 0 and tool_calls <= 10) else 10")).not.toThrow();
  });

  it("rejects disallowed function", () => {
    expect(() => validateExpression("abs(input_tokens)")).toThrow(ExpressionError);
  });

  it("rejects expression with no variables", () => {
    expect(() => validateExpression("42")).toThrow(ExpressionError);
    expect(() => validateExpression("2 + 2")).toThrow(ExpressionError);
  });

  it("rejects syntax errors", () => {
    expect(() => validateExpression("input_tokens **")).toThrow(ExpressionError);
    expect(() => validateExpression("input_tokens +")).toThrow(ExpressionError);
  });
});

describe("evaluateExpression", () => {
  it("evaluates simple arithmetic", () => {
    expect(evaluateExpression("input_tokens * 2", { input_tokens: 100 })).toBe(200);
  });

  it("evaluates combined tokens and output", () => {
    const expr = "input_tokens * (0.001 / 1000) + output_tokens * (0.01 / 1000)";
    const result = evaluateExpression(expr, { input_tokens: 1000, output_tokens: 500 });
    expect(result).toBeCloseTo(0.006, 10);
  });

  it("handles tool_calls count", () => {
    expect(evaluateExpression("tool_calls * 5 / 1000", { tool_calls: 10 })).toBe(0.05);
  });

  it("evaluates ceil function", () => {
    expect(evaluateExpression("ceil(input_tokens * 0.001)", { input_tokens: 1500 })).toBe(2);
  });

  it("evaluates floor function", () => {
    expect(evaluateExpression("floor(output_tokens / 1000)", { output_tokens: 1500 })).toBe(1);
  });

  it("evaluates min function", () => {
    expect(evaluateExpression("min(input_tokens, output_tokens) * 0.5", { input_tokens: 100, output_tokens: 200 })).toBe(50);
  });

  it("evaluates max function", () => {
    expect(evaluateExpression("max(0, tool_calls - 5)", { tool_calls: 10 })).toBe(5);
  });

  it("evaluates round function", () => {
    expect(evaluateExpression("round(input_tokens * 0.001)", { input_tokens: 1500 })).toBe(2);
  });

  it("evaluates ternary (greater than)", () => {
    expect(evaluateExpression("output_tokens * 0.5 if output_tokens > 1000 else output_tokens * 0.3", { output_tokens: 2000 })).toBe(1000);
    expect(evaluateExpression("output_tokens * 0.5 if output_tokens > 1000 else output_tokens * 0.3", { output_tokens: 500 })).toBe(150);
  });

  it("evaluates comparisons", () => {
    expect(evaluateExpression("0 if tool_calls == 0 else tool_calls * 2", { tool_calls: 0 })).toBe(0);
    expect(evaluateExpression("0 if tool_calls == 0 else tool_calls * 2", { tool_calls: 5 })).toBe(10);
  });

  it("evaluates boolean and", () => {
    expect(evaluateExpression("5 if (tool_calls > 0 and tool_calls <= 10) else 10", { tool_calls: 5 })).toBe(5);
    expect(evaluateExpression("5 if (tool_calls > 0 and tool_calls <= 10) else 10", { tool_calls: 15 })).toBe(10);
  });

  it("evaluates boolean or", () => {
    expect(evaluateExpression("20 if (tool_calls > 10 or input_tokens > 1000) else 10", { tool_calls: 5, input_tokens: 2000 })).toBe(20);
  });

  it("handles division by zero", () => {
    expect(evaluateExpression("input_tokens / 0", { input_tokens: 100 })).toBe(Infinity);
  });

  it("handles power operator", () => {
    expect(evaluateExpression("input_tokens ** 2", { input_tokens: 5 })).toBe(25);
  });

  it("handles floor division", () => {
    expect(evaluateExpression("input_tokens // 3", { input_tokens: 10 })).toBe(3);
  });

  it("handles modulo", () => {
    expect(evaluateExpression("input_tokens % 3", { input_tokens: 10 })).toBe(1);
  });

  it("handles unary minus", () => {
    expect(evaluateExpression("-input_tokens", { input_tokens: 50 })).toBe(-50);
  });

  it("rejects undefined variable", () => {
    expect(() => evaluateExpression("undefined_var * 2", { input_tokens: 100 })).toThrow(ExpressionError);
  });
});
