# Security Policy

## Reporting a Vulnerability

Report security vulnerabilities by opening a [GitHub issue](https://github.com/apoorwv/ducto/issues/new).

Do not disclose security vulnerabilities in public GitHub issues if they involve
remote code execution, authentication bypass, or sensitive data exposure.
Instead, describe the finding at a high level and request a private channel.

## Scope

The ducto expression engine (`expr.py`) is designed to reject arbitrary code
execution via Python's AST allowlist. If you find a bypass of this allowlist
that allows unauthorized computation or data access, please report it
immediately.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅        |
