import { readFile } from "node:fs/promises";
import { parse } from "kdljs";

const names = ["background", "surface", "text", "muted", "accent", "positive", "negative", "warning", "info", "violet"] as const;
export type ThemeName = typeof names[number];
export type Theme = Record<ThemeName, string>;
type Node = { name: string; values?: unknown[]; children?: Node[] };

export async function loadTheme(path: string) {
  return parseTheme(await readFile(path, "utf8"));
}

export function parseTheme(source: string): Theme {
  const parsed = parse(source);
  if (parsed.errors?.length) throw new Error(`Zinc theme KDL parse error: ${parsed.errors.map((error) => error.message).join(", ")}`);
  const roots = (parsed.output ?? []) as Node[];
  if (roots.length !== 1 || roots[0].name !== "theme" || roots[0].values?.length) throw new Error("Zinc theme must contain one theme node");
  const children = roots[0].children ?? [], expected = new Set<string>(names), values = new Map<ThemeName, string>();
  for (const node of children) {
    if (!expected.has(node.name)) throw new Error(`Unknown Zinc theme color: ${node.name}`);
    const name = node.name as ThemeName;
    if (values.has(name)) throw new Error(`Duplicate Zinc theme color: ${name}`);
    const value = node.values?.length === 1 ? node.values[0] : undefined;
    if (typeof value !== "string" || !/^#[\da-fA-F]{6}(?:[\da-fA-F]{2})?$/.test(value)) throw new Error(`Zinc theme color must be #RRGGBB or #RRGGBBAA: ${name}`);
    values.set(name, value.toLowerCase());
  }
  for (const name of names) if (!values.has(name)) throw new Error(`Missing Zinc theme color: ${name}`);
  return Object.fromEntries(names.map((name) => [name, values.get(name)!])) as Theme;
}

export function themeCss(theme: Theme) {
  return `:root{${names.map((name) => `--z-${name}:${theme[name]}`).join(";")}}\n`;
}
