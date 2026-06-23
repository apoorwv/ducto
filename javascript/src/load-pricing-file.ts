import { readFileSync } from "fs";

/**
 * Read a JSON or YAML pricing config file from disk.
 *
 * Returns the raw parsed dict (suitable for ``loadConfigFromDict`` or
 * ``PricingEngine.fromDict``).
 *
 * For YAML files the optional peer dep ``js-yaml`` is loaded on demand.
 */
export async function loadPricingFile(filepath: string): Promise<Record<string, unknown>> {
  if (filepath.endsWith(".yaml") || filepath.endsWith(".yml")) {
    let yaml: typeof import("js-yaml");
    try {
      yaml = await import("js-yaml");
    } catch {
      throw new Error("js-yaml required for YAML files: npm install js-yaml");
    }
    const content = readFileSync(filepath, "utf-8");
    return yaml.load(content) as Record<string, unknown>;
  }

  const content = readFileSync(filepath, "utf-8");
  return JSON.parse(content);
}
