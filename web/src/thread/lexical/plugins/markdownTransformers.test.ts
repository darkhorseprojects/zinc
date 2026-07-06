import { $canShowPlaceholder } from "@lexical/text";
import { $createParagraphNode, $getRoot, COMMAND_PRIORITY_BEFORE_EDITOR, COMMAND_PRIORITY_LOW, KEY_ENTER_COMMAND } from "lexical";
import { describe, expect, it } from "vitest";
import { createSolidLexicalEditor } from "~/thread/lexical";
import { exportLexicalToMdx, importMdxToLexical, zincLexicalNodes } from "~/thread/mdx";
import { HORIZONTAL_RULE_TRANSFORMER } from "./markdownTransformers";

function editor() {
  return createSolidLexicalEditor({
    namespace: "zinc-markdown-plugin-test",
    nodes: zincLexicalNodes,
    onError(error) {
      throw error;
    },
  });
}

function canShowPlaceholder(mdx: string) {
  const lexical = editor();
  importMdxToLexical(lexical, mdx);
  let result = false;
  lexical.getEditorState().read(() => {
    result = $canShowPlaceholder(lexical.isComposing());
  });
  return result;
}

describe("Zinc Lexical markdown plugins", () => {
  it("uses Lexical-native placeholder semantics", () => {
    expect(canShowPlaceholder("")).toBe(true);
    expect(canShowPlaceholder("hello")).toBe(false);
    expect(canShowPlaceholder("---")).toBe(false);
    expect(canShowPlaceholder("<Reasoning>\nthink\n</Reasoning>")).toBe(false);
  });

  it("keeps prompt submit behind low-priority Enter shortcuts but ahead of editor defaults", () => {
    const lexical = editor();
    let promptSubmitted = false;
    let shortcutRan = false;
    const unregisterShortcut = lexical.registerCommand(
      KEY_ENTER_COMMAND,
      () => {
        shortcutRan = true;
        return true;
      },
      COMMAND_PRIORITY_LOW,
    );
    const unregisterPrompt = lexical.registerCommand(
      KEY_ENTER_COMMAND,
      () => {
        promptSubmitted = true;
        return true;
      },
      COMMAND_PRIORITY_BEFORE_EDITOR,
    );

    lexical.dispatchCommand(KEY_ENTER_COMMAND, null);

    expect(shortcutRan).toBe(true);
    expect(promptSubmitted).toBe(false);

    unregisterPrompt();
    unregisterShortcut();
  });

  it("replaces a markdown rule paragraph with a selectable horizontal rule", () => {
    const lexical = editor();
    lexical.update(() => {
      const root = $getRoot();
      root.clear();
      const paragraph = $createParagraphNode();
      root.append(paragraph);
      HORIZONTAL_RULE_TRANSFORMER.replace(paragraph, [], ["---"], false);
    }, { discrete: true });

    expect(HORIZONTAL_RULE_TRANSFORMER.triggerOnEnter).toBe(true);
    expect(exportLexicalToMdx(lexical)).toBe("---");
  });
});
