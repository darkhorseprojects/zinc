import { $createLineBreakNode, $createParagraphNode, $createTextNode, $getRoot, $isParagraphNode, KEY_ENTER_COMMAND } from "lexical";
import { $createHeadingNode } from "@lexical/rich-text";
import { describe, expect, it, vi } from "vitest";
import { createSolidLexicalEditor } from "~/thread/lexical";
import { exportLexicalToMdx, zincLexicalNodes } from "~/thread/mdx";
import { registerPromptBackspaceReset, resetPromptStyleBeforeBackspace } from "./PromptBackspaceResetPlugin";

function editor() {
  return createSolidLexicalEditor({
    namespace: "zinc-prompt-backspace-test",
    nodes: zincLexicalNodes,
    onError(error) {
      throw error;
    },
  });
}

function keyboardEvent() {
  return { preventDefault: vi.fn() } as unknown as KeyboardEvent;
}

describe("PromptBackspaceResetPlugin", () => {
  it("does not intercept Shift+Enter", () => {
    const lexical = editor();
    const unregister = registerPromptBackspaceReset(lexical, () => true);

    expect(lexical.dispatchCommand(KEY_ENTER_COMMAND, { shiftKey: true } as KeyboardEvent)).toBe(false);

    unregister();
  });

  it("leaves Backspace native at a plain soft break", () => {
    const lexical = editor();
    const event = keyboardEvent();
    let handled = true;

    lexical.update(() => {
      const root = $getRoot();
      root.clear();
      const paragraph = $createParagraphNode().append($createTextNode("first"), $createLineBreakNode());
      root.append(paragraph);
      paragraph.select(2, 2);
      handled = resetPromptStyleBeforeBackspace(event);
    }, { discrete: true });

    expect(handled).toBe(false);
    expect(event.preventDefault).not.toHaveBeenCalled();
  });

  it("moves styled soft-break continuation into a plain paragraph on Backspace", () => {
    const lexical = editor();
    const event = keyboardEvent();
    let handled = false;
    let secondBlockIsPlainParagraph = false;

    lexical.update(() => {
      const root = $getRoot();
      root.clear();
      const continuation = $createTextNode("plain continuation");
      const heading = $createHeadingNode("h2").append($createTextNode("Heading"), $createLineBreakNode(), continuation);
      root.append(heading);
      continuation.select(0, 0);

      handled = resetPromptStyleBeforeBackspace(event);
      secondBlockIsPlainParagraph = $isParagraphNode(root.getChildAtIndex(1));
    }, { discrete: true });

    expect(handled).toBe(true);
    expect(event.preventDefault).toHaveBeenCalledOnce();
    expect(secondBlockIsPlainParagraph).toBe(true);
    expect(exportLexicalToMdx(lexical)).toBe("## Heading\n\nplain continuation");
  });
});
