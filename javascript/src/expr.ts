import { ExpressionError } from "./errors.js";

const ALLOWED_FUNCTIONS = new Set(["ceil", "floor", "min", "max", "round"]);

// ── Tokenizer ──────────────────────────────────────────────────────────────

type TokenType =
  | "number" | "identifier"
  | "+" | "-" | "*" | "/" | "//" | "%" | "**"
  | "(" | ")" | ","
  | "==" | "!=" | "<" | "<=" | ">" | ">=" | "in" | "not"
  | "and" | "or"
  | "if" | "else";

interface Token {
  type: TokenType;
  value: string;
}

function tokenize(src: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < src.length) {
    if (src[i] === " " || src[i] === "\t" || src[i] === "\n") { i++; continue; }
    if (src[i] === "(") { tokens.push({ type: "(", value: "(" }); i++; continue; }
    if (src[i] === ")") { tokens.push({ type: ")", value: ")" }); i++; continue; }
    if (src[i] === ",") { tokens.push({ type: ",", value: "," }); i++; continue; }

    // Two-char operators
    const two = src.slice(i, i + 2);
    if (two === "**") { tokens.push({ type: "**", value: "**" }); i += 2; continue; }
    if (two === "//") { tokens.push({ type: "//", value: "//" }); i += 2; continue; }
    if (two === "==") { tokens.push({ type: "==", value: "==" }); i += 2; continue; }
    if (two === "!=") { tokens.push({ type: "!=", value: "!=" }); i += 2; continue; }
    if (two === "<=") { tokens.push({ type: "<=", value: "<=" }); i += 2; continue; }
    if (two === ">=") { tokens.push({ type: ">=", value: ">=" }); i += 2; continue; }

    // "not in" needs special handling — we tokenize "not" and then "in" separately
    // The parser will handle "not" + "in" as "not in"

    // One-char operators
    if (src[i] === "+") { tokens.push({ type: "+", value: "+" }); i++; continue; }
    if (src[i] === "-") { tokens.push({ type: "-", value: "-" }); i++; continue; }
    if (src[i] === "*") { tokens.push({ type: "*", value: "*" }); i++; continue; }
    if (src[i] === "/") { tokens.push({ type: "/", value: "/" }); i++; continue; }
    if (src[i] === "%") { tokens.push({ type: "%", value: "%" }); i++; continue; }
    if (src[i] === "<") { tokens.push({ type: "<", value: "<" }); i++; continue; }
    if (src[i] === ">") { tokens.push({ type: ">", value: ">" }); i++; continue; }

    // Numbers
    if (/[0-9]/.test(src[i])) {
      let num = "";
      while (i < src.length && (/[0-9.]/.test(src[i]))) { num += src[i]; i++; }
      tokens.push({ type: "number", value: num });
      continue;
    }

    // Identifiers and keywords
    if (/[a-zA-Z_]/.test(src[i])) {
      let word = "";
      while (i < src.length && /[a-zA-Z0-9_]/.test(src[i])) { word += src[i]; i++; }
      const kw: TokenType =
        word === "and" ? "and" :
        word === "or" ? "or" :
        word === "if" ? "if" :
        word === "else" ? "else" :
        word === "in" ? "in" :
        word === "not" ? "not" :
        word === "true" ? "number" :
        word === "false" ? "number" :
        "identifier";
      tokens.push({
        type: kw,
        value: word === "true" ? "1" : word === "false" ? "0" : word,
      });
      continue;
    }

    throw new ExpressionError(`unexpected character: '${src[i]}'`);
  }
  return tokens;
}

// ── AST nodes ──────────────────────────────────────────────────────────────

export interface NumNode { type: "number"; value: number; }
export interface IdentNode { type: "identifier"; name: string; }
export interface BinOpNode { type: "binary"; op: string; left: Node; right: Node; }
export interface UnaryNode { type: "unary"; op: string; operand: Node; }
export interface CallNode { type: "call"; name: string; args: Node[]; }
export interface TernaryNode { type: "ternary"; cond: Node; then: Node; else: Node; }
export interface CompareNode { type: "comparison"; op: string; left: Node; right: Node; }
export interface BoolOpNode { type: "boolean"; op: string; left: Node; right: Node; }

export type Node = NumNode | IdentNode | BinOpNode | UnaryNode | CallNode | TernaryNode | CompareNode | BoolOpNode;

// ── Parser ─────────────────────────────────────────────────────────────────

class Parser {
  private tokens: Token[];
  private pos = 0;

  constructor(tokens: Token[]) {
    this.tokens = tokens;
  }

  peek(): Token | undefined { return this.tokens[this.pos]; }
  private previous(): Token { return this.tokens[this.pos - 1]; }
  isAtEnd(): boolean { return this.pos >= this.tokens.length; }

  private check(...types: TokenType[]): boolean {
    if (this.isAtEnd()) return false;
    return types.includes(this.tokens[this.pos].type);
  }

  private match(...types: TokenType[]): boolean {
    for (const t of types) {
      if (this.check(t)) { this.pos++; return true; }
    }
    return false;
  }

  private consume(type: TokenType, msg: string): Token {
    if (this.check(type)) return this.tokens[this.pos++];
    throw new ExpressionError(msg);
  }

  parse(): Node {
    let expr = this.boolExpr();

    // Handle ternary: X if cond else Y (at top level so operators bind correctly)
    if (this.match("if")) {
      const cond = this.boolExpr();
      this.consume("else", "expected 'else' in ternary expression");
      const elseBranch = this.boolExpr();
      return { type: "ternary", cond, then: expr, else: elseBranch } as TernaryNode;
    }

    return expr;
  }

  private boolExpr(): Node {
    let left = this.comparison();
    while (this.match("and", "or")) {
      const op = this.previous().value;
      const right = this.comparison();
      left = { type: "boolean", op, left, right } as BoolOpNode;
    }
    return left;
  }

  private comparison(): Node {
    let left = this.addition();
    // Handle "not in" as two tokens
    if (this.match("not") && this.match("in")) {
      const right = this.addition();
      left = { type: "comparison", op: "not in", left, right } as CompareNode;
    }
    while (this.match("==", "!=", "<", "<=", ">", ">=", "in")) {
      const op = this.previous().value;
      const right = this.addition();
      left = { type: "comparison", op, left, right } as CompareNode;
    }
    return left;
  }

  private addition(): Node {
    let left = this.multiplication();
    while (this.match("+", "-")) {
      const op = this.previous().value;
      const right = this.multiplication();
      left = { type: "binary", op, left, right } as BinOpNode;
    }
    return left;
  }

  private multiplication(): Node {
    let left = this.unary();
    while (this.match("*", "/", "//", "%", "**")) {
      const op = this.previous().value;
      const right = this.unary();
      left = { type: "binary", op, left, right } as BinOpNode;
    }
    return left;
  }

  private unary(): Node {
    if (this.match("+", "-")) {
      const op = this.previous().value;
      return { type: "unary", op, operand: this.unary() } as UnaryNode;
    }
    return this.callOrPrimary();
  }

  private callOrPrimary(): Node {
    return this.primary();
  }

  private primary(): Node {
    if (this.match("number")) {
      return { type: "number", value: parseFloat(this.previous().value) } as NumNode;
    }
    if (this.match("identifier")) {
      const name = this.previous().value;
      // Check if this is a function call like ceil(...)
      if (this.match("(")) {
        const args: Node[] = [];
        if (!this.check(")")) {
          do { args.push(this.boolExpr()); } while (this.match(","));
        }
        this.consume(")", "expected ')'");
        if (!ALLOWED_FUNCTIONS.has(name)) {
          throw new ExpressionError(`disallowed function: ${name}`);
        }
        return { type: "call", name, args } as CallNode;
      }
      return { type: "identifier", name } as IdentNode;
    }
    if (this.match("(")) {
      const expr = this.parse();
      this.consume(")", "expected ')'");
      return expr;
    }
    throw new ExpressionError(`unexpected token: '${this.peek()?.value ?? "EOF"}'`);
  }
}

// ── Validation ─────────────────────────────────────────────────────────────

function validateVariables(node: Node): void {
  const seen: Set<string> = new Set();
  function walk(n: Node): void {
    if (n.type === "identifier" && !ALLOWED_FUNCTIONS.has(n.name)) {
      seen.add(n.name);
    }
    for (const child of children(n)) walk(child);
  }
  walk(node);
  if (seen.size === 0) {
    throw new ExpressionError("expression references no variables -- must use at least one metric");
  }
}

function children(n: Node): Node[] {
  switch (n.type) {
    case "binary": return [n.left, n.right];
    case "unary": return [n.operand];
    case "call": return n.args;
    case "ternary": return [n.cond, n.then, n.else];
    case "comparison": return [n.left, n.right];
    case "boolean": return [n.left, n.right];
    case "number":
    case "identifier": return [];
  }
}

// ── Public API ─────────────────────────────────────────────────────────────

/** Validate that an expression string is safe and syntactically valid. */
export function validateExpression(expr: string): void {
  try {
    const tokens = tokenize(expr);
    const parser = new Parser(tokens);
    const node = parser.parse();
    if (!parser.isAtEnd()) {
      throw new ExpressionError(`unexpected token after expression: '${parser.peek()?.value}'`);
    }
    validateVariables(node);
  } catch (e) {
    if (e instanceof ExpressionError) throw e;
    throw new ExpressionError(`invalid expression: ${(e as Error).message}`);
  }
}

/** Safely evaluate a validated expression. */
export function evaluateExpression(
  expr: string,
  variables: Record<string, number>,
): number {
  if (!variables || typeof variables !== "object") {
    throw new ExpressionError("variables must be a dict");
  }
  if (Object.keys(variables).length === 0) {
    throw new ExpressionError("cannot evaluate: variables dict is empty");
  }

  let tokens: Token[];
  try {
    tokens = tokenize(expr);
  } catch (e) {
    throw new ExpressionError(`syntax error: ${(e as Error).message}`);
  }

  const parser = new Parser(tokens);
  const node = parser.parse();
  if (!parser.isAtEnd()) {
    throw new ExpressionError(`unexpected token: '${parser.peek()?.value}'`);
  }

  // Validate undefined variables
  function checkVars(n: Node): void {
    if (n.type === "identifier" && !ALLOWED_FUNCTIONS.has(n.name) && !(n.name in variables)) {
      throw new ExpressionError(`undefined variable: '${n.name}'`);
    }
    for (const child of children(n)) checkVars(child);
  }
  checkVars(node);

  return evaluateNode(node, variables);
}

function evaluateNode(node: Node, vars: Record<string, number>): number {
  switch (node.type) {
    case "number":
      return node.value;

    case "identifier":
      return vars[node.name] ?? 0;

    case "unary": {
      const v = evaluateNode(node.operand, vars);
      return node.op === "-" ? -v : v;
    }

    case "binary": {
      const l = evaluateNode(node.left, vars);
      const r = evaluateNode(node.right, vars);
      switch (node.op) {
        case "+": return l + r;
        case "-": return l - r;
        case "*": return l * r;
        case "/": return r === 0 ? Infinity : l / r;
        case "//": return r === 0 ? Infinity : Math.floor(l / r);
        case "%": return r === 0 ? NaN : l % r;
        case "**": return Math.pow(l, r);
        default: throw new ExpressionError(`unknown operator: ${node.op}`);
      }
    }

    case "call": {
      const args = node.args.map((a) => evaluateNode(a, vars));
      switch (node.name) {
        case "ceil": return Math.ceil(args[0]);
        case "floor": return Math.floor(args[0]);
        case "min": return Math.min(...args);
        case "max": return Math.max(...args);
        case "round": return Math.round(args[0]);
        default: throw new ExpressionError(`disallowed function: ${node.name}`);
      }
    }

    case "ternary":
      return evaluateNode(node.cond, vars)
        ? evaluateNode(node.then, vars)
        : evaluateNode(node.else, vars);

    case "comparison": {
      const l = evaluateNode(node.left, vars);
      const r = evaluateNode(node.right, vars);
      switch (node.op) {
        case "==": return l === r ? 1 : 0;
        case "!=": return l !== r ? 1 : 0;
        case "<": return l < r ? 1 : 0;
        case "<=": return l <= r ? 1 : 0;
        case ">": return l > r ? 1 : 0;
        case ">=": return l >= r ? 1 : 0;
        case "in": return String(l).includes(String(r)) ? 1 : 0;
        case "not in": return String(l).includes(String(r)) ? 0 : 1;
        default: throw new ExpressionError(`unknown comparison: ${node.op}`);
      }
    }

    case "boolean": {
      const l = evaluateNode(node.left, vars);
      const r = evaluateNode(node.right, vars);
      switch (node.op) {
        case "and": return l && r ? 1 : 0;
        case "or": return l || r ? 1 : 0;
        default: throw new ExpressionError(`unknown boolean op: ${node.op}`);
      }
    }
  }
}
