export type LiquidGlassOptions = {
  radius?: number;
  thickness?: number;
  ior?: number;
  dispersion?: number;
  scale?: number;
  scaleRatio?: number;
  maxScale?: number;
};

export type NormalizedLiquidGlassOptions = Required<LiquidGlassOptions> & {
  rimRadius: number;
  warpBand: number;
};

export type LiquidGlassMap = {
  width: number;
  height: number;
  radius: number;
  thickness: number;
  rimRadius: number;
  warpBand: number;
  ior: number;
  dispersion: number;
  scale: number;
  redScale: number;
  greenScale: number;
  blueScale: number;
  displacement: string;
};

export type LiquidGlassPixel = {
  displacement: [number, number, number, number];
  rim: number;
  displacementMagnitude: number;
  redScale: number;
  greenScale: number;
  blueScale: number;
};
