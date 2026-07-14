const tagPattern = /#[\p{L}\p{N}_-]+/gu;
export type IdentifierParts = { value: string; tags: string[]; title: string };

export function parseIdentifier(value: string): IdentifierParts {
  const clean = value.trim().replace(/[\t ]+/g, " "), tags = [...clean.matchAll(tagPattern)].map((match) => match[0]), title = clean.replace(tagPattern, " ").trim().replace(/[\t ]+/g, " ");
  return { value: [...tags, title].filter(Boolean).join(" "), tags, title };
}
export function identifierSuggestion(markdown: string) { const plain = markdown.replace(/```[\s\S]*?```/g, " ").replace(/[*_~`$#[\]()>|\\-]/g, " ").replace(/\s+/g, " ").trim(); return plain.split(" ").slice(0, 7).join(" ").slice(0, 60); }
export function tagColor(tag: string, count = 6) { let hash = 2166136261; for (const character of tag.toLocaleLowerCase()) { hash ^= character.codePointAt(0) ?? 0; hash = Math.imul(hash, 16777619); } return Math.abs(hash) % count; }
