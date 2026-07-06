import type { LiquidGlassMap, LiquidGlassOptions, LiquidGlassPixel, NormalizedLiquidGlassOptions } from "./types";

const cache = new Map<string, LiquidGlassMap>();
const defaults = { radius: 18, ior: 1.52, dispersion: 0.008, scaleRatio: 1, maxScale: 40 };

type Scales = Record<"red" | "green" | "blue", number>;
type Sample = { height: number; opacity: number; normal: readonly [number, number, number] };

export function createLiquidGlassMap(width: number, height: number, options: LiquidGlassOptions = {}): LiquidGlassMap {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  const glass = normalizeOptions(w, h, options);
  const scales = wavelengthScales(glass);
  const key = cacheKey(w, h, glass, scales);
  const existing = cache.get(key);
  if (existing) return existing;

  const map = {
    width: w,
    height: h,
    radius: glass.radius,
    thickness: glass.thickness,
    rimRadius: glass.rimRadius,
    warpBand: glass.warpBand,
    ior: glass.ior,
    dispersion: glass.dispersion,
    scale: scales.green,
    redScale: scales.red,
    greenScale: scales.green,
    blueScale: scales.blue,
    displacement: renderMap(w, h, (x, y) => displacementPixel(w, h, x, y, glass).rgba),
  } satisfies LiquidGlassMap;

  cache.set(key, map);
  return map;
}

export function sampleLiquidGlassPixel(width: number, height: number, x: number, y: number, options: LiquidGlassOptions = {}): LiquidGlassPixel {
  const w = Math.max(1, Math.round(width));
  const h = Math.max(1, Math.round(height));
  const glass = normalizeOptions(w, h, options);
  const scales = wavelengthScales(glass);
  const pixel = displacementPixel(w, h, x, y, glass);

  return {
    displacement: pixel.rgba,
    rim: rimSample(w, h, x, y, glass.radius, glass.warpBand)?.height ?? 0,
    displacementMagnitude: pixel.magnitude,
    redScale: scales.red,
    greenScale: scales.green,
    blueScale: scales.blue,
  };
}

export function normalizeOptions(width: number, height: number, options: LiquidGlassOptions): NormalizedLiquidGlassOptions {
  const radius = clamp(options.radius ?? defaults.radius, 1, Math.max(1, Math.min(width, height) / 2));
  const thickness = Math.max(1, options.thickness ?? radius * 1.4);
  const rimRadius = Math.min(radius, Math.max(1, Math.min(width, height) / 2 - 1));
  const scaleRatio = Math.max(0, options.scaleRatio ?? defaults.scaleRatio);
  const maxScale = Math.max(0, options.maxScale ?? defaults.maxScale);
  const scale = clamp(options.scale ?? (thickness / radius) * 30 * scaleRatio, 0, maxScale);

  return {
    radius,
    thickness,
    rimRadius,
    warpBand: rimRadius,
    ior: Math.max(1.01, options.ior ?? defaults.ior),
    dispersion: Math.max(0, options.dispersion ?? defaults.dispersion),
    scale,
    scaleRatio,
    maxScale,
  };
}

function displacementPixel(width: number, height: number, x: number, y: number, glass: NormalizedLiquidGlassOptions) {
  const sample = rimSample(width, height, x, y, glass.radius, glass.warpBand);
  if (!sample) return { rgba: neutral(), magnitude: 0 };

  const bend = clamp((glass.ior - 1) / 0.62, 0.08, 1.4) * sample.opacity;
  const dx = sample.normal[0] * bend;
  const dy = sample.normal[1] * bend;

  return {
    rgba: [byte(128 + dx * 116), byte(128 + dy * 116), 0, 255] as [number, number, number, number],
    magnitude: Math.hypot(dx, dy),
  };
}

function rimSample(width: number, height: number, x: number, y: number, radius: number, band: number): Sample | null {
  const r = Math.min(radius, width / 2, height / 2);
  const corner = cornerTrack(width, height, x, y, r, band);
  if (corner) return corner;

  if (x >= r && x <= width - r) {
    const top = rimTrack(y, band, [0, 1]);
    if (top) return top;
    const bottom = rimTrack(height - y, band, [0, -1]);
    if (bottom) return bottom;
  }

  if (y >= r && y <= height - r) {
    const left = rimTrack(x, band, [1, 0]);
    if (left) return left;
    const right = rimTrack(width - x, band, [-1, 0]);
    if (right) return right;
  }

  return null;
}

function cornerTrack(width: number, height: number, x: number, y: number, radius: number, band: number): Sample | null {
  const cx = x < radius ? radius : x > width - radius ? width - radius : null;
  const cy = y < radius ? radius : y > height - radius ? height - radius : null;
  if (cx === null || cy === null) return null;

  const vx = x - cx;
  const vy = y - cy;
  const length = Math.hypot(vx, vy);
  if (length > radius + 1 || length < 0.5) return null;

  return rimTrack(radius - length, Math.min(band, radius), [-vx / length, -vy / length]);
}

function rimTrack(inward: number, available: number, direction: readonly [number, number]): Sample | null {
  if (inward < -1 || inward > available) return null;
  const opacity = inward < 0 ? 1 + inward : 1;
  if (opacity <= 0) return null;

  const t = clamp(inward / available, 0, 1);
  const bend = Math.cos(smootherstep(t) * Math.PI * 0.5);
  return { height: bend, opacity, normal: [direction[0] * bend, direction[1] * bend, t] as const };
}

function renderMap(width: number, height: number, pixelAt: (x: number, y: number) => [number, number, number, number]) {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const canvas2d = canvas.getContext("2d", { willReadFrequently: false });
  if (!canvas2d) throw new Error("Liquid glass requires a 2D canvas.");

  const image = canvas2d.createImageData(width, height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    image.data.set(pixelAt(x + 0.5, y + 0.5), (y * width + x) * 4);
  }
  canvas2d.putImageData(image, 0, 0);
  return canvas.toDataURL("image/png");
}

function wavelengthScales(glass: NormalizedLiquidGlassOptions): Scales {
  const split = clamp(glass.dispersion * 18, 0, 0.28);
  return {
    red: clamp(glass.scale * (1 + split), 0, glass.maxScale),
    green: glass.scale,
    blue: clamp(glass.scale * (1 - split), 0, glass.maxScale),
  };
}

function cacheKey(width: number, height: number, glass: NormalizedLiquidGlassOptions, scales: Scales) {
  return [width, height, glass.radius, glass.thickness, glass.rimRadius, glass.ior, glass.dispersion, glass.scale, scales.red, scales.green, scales.blue].join(":");
}

function smootherstep(value: number) {
  const t = clamp(value, 0, 1);
  return t * t * t * (t * (t * 6 - 15) + 10);
}

function neutral(): [number, number, number, number] { return [128, 128, 0, 255]; }
function byte(value: number) { return Math.round(clamp(value, 0, 255)); }
function clamp(value: number, min: number, max: number) { return Math.min(max, Math.max(min, value)); }
