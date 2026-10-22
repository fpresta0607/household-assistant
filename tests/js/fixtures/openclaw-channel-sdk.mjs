import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";

const SDK_IMPORT = /import\s*\{([^}]*)\}\s*from\s*"(openclaw\/plugin-sdk\/[^"]+)"/g;

// Stands in for the OpenClaw plugin SDK, which only the gateway's image carries, so a test
// can import a channel plugin's entry. Each SDK module exports exactly what the entry
// imports from it, read from the entry itself: createChatChannelPlugin spreads its base
// the way 2026.9.4's does, a constant is its own name, and anything else hands back its
// first argument. A test that runs the channel itself names the few it needs to behave
// in `overrides`, each as the source of the function that stands in for it.
export function stubChannelSdk(entry, overrides = {}) {
  const modules = new Map();
  for (const [, names, specifier] of readFileSync(entry, "utf8").matchAll(SDK_IMPORT)) {
    const source = names.split(",").map((name) => name.trim()).filter(Boolean).map((name) => {
      if (overrides[name]) return `export const ${name} = ${overrides[name]};`;
      if (name === "createChatChannelPlugin") return `export const ${name} = (params) => ({ ...params.base });`;
      if (/^[A-Z_]+$/.test(name)) return `export const ${name} = ${JSON.stringify(name)};`;
      return `export const ${name} = (value) => value;`;
    });
    modules.set(specifier, `data:text/javascript;base64,${Buffer.from(source.join("\n")).toString("base64")}`);
  }
  return registerHooks({
    resolve(specifier, context, nextResolve) {
      const url = modules.get(specifier);
      return url ? { url, shortCircuit: true } : nextResolve(specifier, context);
    },
  });
}
