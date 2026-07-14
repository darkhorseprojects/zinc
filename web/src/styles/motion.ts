export const motion = { reveal: 120, fast: 160, normal: 220, reorder: 300, spinner: 850 } as const;
export const ease = { standard: "outQuad", spatial: "outCubic", linear: "linear" } as const;
export function duration(value: number) { return typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : value; }
