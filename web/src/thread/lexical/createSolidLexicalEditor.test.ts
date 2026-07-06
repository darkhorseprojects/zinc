import { $createParagraphNode, $createTextNode, $getRoot } from "lexical";
import { describe, expect, it } from "vitest";
import { createSolidLexicalEditor } from "./createSolidLexicalEditor";

describe("createSolidLexicalEditor", () => {
  it("creates a framework-agnostic Lexical editor", () => {
    const editor = createSolidLexicalEditor({
      namespace: "zinc-test",
      onError(error) {
        throw error;
      },
    });

    expect(editor.getRootElement()).toBeNull();
    expect(editor.isEditable()).toBe(true);
  });

  it("keeps editable state under Lexical control", () => {
    const editor = createSolidLexicalEditor({
      namespace: "zinc-editable-test",
      editable: false,
      onError(error) {
        throw error;
      },
    });

    expect(editor.isEditable()).toBe(false);
    editor.setEditable(true);
    expect(editor.isEditable()).toBe(true);
  });

  it("commits updates through Lexical editor state", async () => {
    const editor = createSolidLexicalEditor({
      namespace: "zinc-update-test",
      onError(error) {
        throw error;
      },
    });

    const committed = new Promise<string>((resolve) => {
      const unregister = editor.registerUpdateListener(({ editorState }) => {
        unregister();
        editorState.read(() => resolve($getRoot().getTextContent()));
      });
    });

    editor.update(() => {
      const root = $getRoot();
      root.clear();
      root.append($createParagraphNode().append($createTextNode("hello lexical")));
    });

    expect(await committed).toBe("hello lexical");
  });
});
