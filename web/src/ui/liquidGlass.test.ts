import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { normalizeOptions, promptLiquidGlassOptions, sampleLiquidGlassPixel } from "./liquidGlass";

describe("liquid glass displacement field", () => {
  it("uses one displacement field for wavelength-split RGB displacement", () => {
    const source = readFileSync(new URL("../thread/DraftDock.tsx", import.meta.url), "utf8");

    expect(source.match(/<feImage\b/g)).toHaveLength(1);
    expect(source).toContain('result="map"');
    expect(source).toContain('<feGaussianBlur in="SourceGraphic" stdDeviation="3" result="softSource" />');
    expect(source).toContain('in="softSource" in2="map" scale={String(glass()?.redScale ?? 0)}');
    expect(source).toContain('in="softSource" in2="map" scale={String(glass()?.greenScale ?? 0)}');
    expect(source).toContain('in="softSource" in2="map" scale={String(glass()?.blueScale ?? 0)}');
    expect(source).toContain('result="onlyR"');
    expect(source).toContain('result="onlyG"');
    expect(source).toContain('result="onlyB"');
    expect(source).toContain('<feFuncR type="identity" />');
    expect(source).toContain('<feFuncA type="identity" />');
    expect(source).not.toContain('specularFaded');
    expect(source).not.toContain('<feBlend');
    expect(source.match(/operator="arithmetic"/g)).toHaveLength(2);
    expect(source).not.toMatch(/softMap|lighten|blurredSource|scale="34"|scale="30"|scale="26"/);
  });

  it("applies the SVG backdrop filter to the prompt shell only after maps exist", () => {
    const component = readFileSync(new URL("../thread/DraftDock.tsx", import.meta.url), "utf8");
    const css = readFileSync(new URL("../app.css", import.meta.url), "utf8");

    expect(component).toContain("getComputedStyle(shellRef).borderTopLeftRadius");
    expect(component).toContain("thickness: radius * 1.75");
    expect(component).not.toMatch(/warpBand:\s*radius/);
    expect(component).toContain('data-glass-ready={glass() ? "true" : undefined}');
    expect(component).not.toContain('prompt-glass-surface');
    expect(css).toMatch(/\.prompt-shell\[data-glass-ready="true"\]\s*\{[^}]*backdrop-filter:\s*url\(#prompt-glass-distortion\);/s);
    expect(css).not.toMatch(/\.prompt-shell\[data-glass-ready="true"\]::before/);
    expect(css).not.toMatch(/-webkit-backdrop-filter/);
    expect(css).not.toMatch(/backdrop-filter:\s*[^;]*(blur|saturate|brightness)\(/);
    const promptReadyRule = css.match(/\.prompt-shell\[data-glass-ready="true"\]\s*\{[^}]*\}/s)?.[0] ?? "";
    expect(promptReadyRule).toContain("border: 0;");
    expect(promptReadyRule).toContain("background: rgb(14 21 32 / 0.42);");
    expect(promptReadyRule).not.toContain("linear-gradient");
    expect(css).not.toMatch(/\.prompt-shell\[data-glass-ready="true"\]::after|0 18px 48px|mix-blend-mode:\s*(screen|lighten)|inset 0 0 30px/);
  });

  it("renders one map for the shared displacement field", () => {
    const maps = readFileSync(new URL("./liquidGlass/maps.ts", import.meta.url), "utf8");

    expect(maps).toContain("displacement: renderMap");
    expect(maps).not.toContain("redDisplacement: renderMap");
    expect(maps).not.toContain("greenDisplacement: renderMap");
    expect(maps).not.toContain("blueDisplacement: renderMap");
    expect(maps).not.toContain("specular: renderMap");
    expect(maps).toContain("rimSample");
    expect(maps).toContain("cornerTrack");
    expect(maps).toContain("rimTrack");
    expect(maps).not.toContain("signedDistance");
    expect(maps).not.toContain("outsideX");
    expect(maps).not.toContain("cornerRim");
    expect(maps).not.toContain("sideRim");
    expect(maps).not.toContain("roundedRectDistance");
    expect(maps).not.toContain("insetRoundedRectNormal");
    expect(maps).not.toContain("circularRimSlope");
    expect(maps).not.toContain("calculateRefractionProfile");
  });

  it("keeps the optical center neutral", () => {
    const pixel = sampleLiquidGlassPixel(240, 120, 120, 60, promptLiquidGlassOptions);

    expect(pixel.rim).toBe(0);
    expect(pixel.displacement).toEqual([128, 128, 0, 255]);
    expect(pixel.displacementMagnitude).toBe(0);
  });

  it("uses physical wavelength IOR order for chromatic maps", () => {
    const pixel = sampleLiquidGlassPixel(240, 120, 1, 60, promptLiquidGlassOptions);

    expect(pixel.redScale).toBeGreaterThan(pixel.greenScale);
    expect(pixel.greenScale).toBeGreaterThan(pixel.blueScale);
  });

  it("bakes IOR into the displacement map", () => {
    const lowIor = sampleLiquidGlassPixel(240, 120, 8, 60, { ...promptLiquidGlassOptions, ior: 1.1 });
    const highIor = sampleLiquidGlassPixel(240, 120, 8, 60, { ...promptLiquidGlassOptions, ior: 1.62 });

    expect(highIor.displacementMagnitude).not.toBe(lowIor.displacementMagnitude);
  });

  it("derives visual bands from one radius-based thickness", () => {
    const options = normalizeOptions(240, 120, { ...promptLiquidGlassOptions, radius: 18, thickness: 18 * 2.05 });
    const outerEdge = sampleLiquidGlassPixel(240, 120, 1, 60, { ...promptLiquidGlassOptions, radius: 18, thickness: 18 * 2.05 });
    const midRim = sampleLiquidGlassPixel(240, 120, 18, 60, { ...promptLiquidGlassOptions, radius: 18, thickness: 18 * 2.05 });
    const outsideBand = sampleLiquidGlassPixel(240, 120, 31, 60, { ...promptLiquidGlassOptions, radius: 18, thickness: 18 * 2.05 });

    expect(options.thickness).toBeCloseTo(18 * 2.05);
    expect(options.warpBand).toBeCloseTo(18);
    expect(options.rimRadius).toBe(options.warpBand);
    expect(outerEdge.displacementMagnitude).toBeGreaterThan(midRim.displacementMagnitude);
    expect(midRim.displacementMagnitude).toBeCloseTo(0);
    expect(outsideBand.displacementMagnitude).toBe(0);
    expect(outerEdge.rim).toBeGreaterThan(midRim.rim);
  });

  it("caps prompt displacement in pixel space", () => {
    const options = normalizeOptions(820, 132, promptLiquidGlassOptions);
    const pixel = sampleLiquidGlassPixel(820, 132, 1, 66, promptLiquidGlassOptions);

    expect(options.scale).toBeLessThanOrEqual(options.maxScale);
    expect(pixel.blueScale).toBeLessThanOrEqual(options.maxScale * 1.05);
  });

  it("does not saturate the outer displacement map", () => {
    const edge = sampleLiquidGlassPixel(240, 120, 0, 60, promptLiquidGlassOptions);

    expect(edge.displacement[0]).toBeGreaterThan(11);
    expect(edge.displacement[0]).toBeLessThan(245);
  });
});
