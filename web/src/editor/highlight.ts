import { c, css, go, java, python, rust } from "sugar-high/presets";
import { tokenize } from "sugar-high";

const core = new Set(["js", "javascript", "jsx", "ts", "typescript", "tsx"]);
const presets: Record<string, Parameters<typeof tokenize>[1]> = { c, css, go, golang: go, java, python, py: python, rust, rs: rust };

export const shellPreset: NonNullable<Parameters<typeof tokenize>[1]> = {
  keywords: new Set(["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "select", "time", "coproc", "break", "continue", "return", "exit", "export", "local", "readonly", "unset", "shift", "source", "alias"]),
  onCommentStart: (current) => current === "#" ? 1 : 0,
  onCommentEnd: (_previous, current) => current === "\n" ? 1 : 0,
};

export function highlight(code: string, language: string | null | undefined) {
  const name = (language ?? "").trim().toLowerCase();
  if (core.has(name)) return tokenize(code);
  const preset = presets[name];
  return preset ? tokenize(code, preset) : null;
}

export function highlightShell(command: string) { return tokenize(command, shellPreset); }
