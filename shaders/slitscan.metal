// Slit-scan with a delay map: every pixel is read from a different point
// in the recent past. The second input is the delay map - its red channel
// picks how many frames back (0 = black = now, 1 = white = the oldest).
// Publish a map with [jet_share delaymap] in another chain (jet_perlin
// gives organic results, a gradient texture a classic scanner look).
// @input src
// @input map delaymap
// @history 30
// @param float maxdelay = 30

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float d = t.map.sample(t.smp, uv).r;
  int delay = int(d * (p.maxdelay - 1.0) + 0.5);
  return jet_history(t, p, uv, delay);
}
