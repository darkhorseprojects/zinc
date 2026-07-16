import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseTheme, themeCss } from "../src/theme.js";

const source = `theme {
  background "#090D12"
  surface "#0e1520"
  text "#e4e9ef"
  muted "#73808d"
  accent "#5d8dff"
  edge "#06090e"
  neutral "#475569"
  line "#becdde"
  rim "#bed2f0"
  positive "#86efac"
  negative "#fca5a5"
  warning "#fbbf24"
  info "#7dd3fc"
  violet "#c4b5fd"
}`;

describe("theme", () => {
  it("parses one strict semantic palette and emits variables", () => {
    const theme = parseTheme(source);
    assert.equal(theme.background, "#090d12");
    assert.match(themeCss(theme), /--z-background:#090d12/);
    assert.match(themeCss(theme), /--z-background-rgb:9 13 18/);
    assert.match(themeCss(theme), /--z-edge:#06090e/);
  });
  it("rejects unknown, missing, duplicate, and non-hex colors", () => {
    assert.throws(() => parseTheme(source.replace("violet \"#c4b5fd\"", "other \"#c4b5fd\"")), /Unknown/);
    assert.throws(() => parseTheme(source.replace(/\s+violet[^\n]+/, "")), /Missing/);
    assert.throws(() => parseTheme(source.replace("surface", "background")), /Duplicate/);
    assert.throws(() => parseTheme(source.replace("#090D12", "red")), /#RRGGBB/);
  });
});
