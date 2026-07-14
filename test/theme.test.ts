import { describe, expect, it } from "vitest";
import { parseTheme, themeCss } from "../src/theme.js";

const source = `theme {
  background "#090D12"
  surface "#0e1520"
  text "#e4e9ef"
  muted "#73808d"
  accent "#5d8dff"
  positive "#86efac"
  negative "#fca5a5"
  warning "#fbbf24"
  info "#7dd3fc"
  violet "#c4b5fd"
}`;

describe("theme", () => {
  it("parses one strict semantic palette and emits variables", () => {
    const theme = parseTheme(source);
    expect(theme.background).toBe("#090d12");
    expect(themeCss(theme)).toContain("--z-background:#090d12");
  });
  it("rejects unknown, missing, duplicate, and non-hex colors", () => {
    expect(() => parseTheme(source.replace("violet \"#c4b5fd\"", "other \"#c4b5fd\""))).toThrow(/Unknown/);
    expect(() => parseTheme(source.replace(/\s+violet[^\n]+/, ""))).toThrow(/Missing/);
    expect(() => parseTheme(source.replace("surface", "background"))).toThrow(/Duplicate/);
    expect(() => parseTheme(source.replace("#090D12", "red"))).toThrow(/#RRGGBB/);
  });
});
