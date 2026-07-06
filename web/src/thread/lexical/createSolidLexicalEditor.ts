import { createEditor, type CreateEditorArgs, type LexicalEditor } from "lexical";

export type SolidLexicalConfig = CreateEditorArgs & {
  namespace: string;
  onError: NonNullable<CreateEditorArgs["onError"]>;
};

export function createSolidLexicalEditor(config: SolidLexicalConfig): LexicalEditor {
  return createEditor(config);
}
