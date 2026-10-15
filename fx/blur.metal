// jet_blur: soft blur in a single pass (a spiral of 32 samples, so it is
// cheap and fine for small and medium radii; very large radii get grainy).
//   radius  blur radius in pixels of the output (0 = unchanged)
// @input src
// @param float radius = 4

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  if(p.radius < 0.01) return t.src.sample(t.smp, uv);
  const int N = 32;
  float2 px = 1.0 / p.resolution;
  float4 sum = float4(0.0);
  float wsum = 0.0;
  for(int i = 0; i < N; i++) {
    float fi = float(i) + 0.5;
    float r = sqrt(fi / float(N));            // even coverage of the disc
    float a = fi * 2.3999632;                 // golden angle
    float2 o = float2(cos(a), sin(a)) * r * p.radius;
    float w = exp(-2.0 * r * r);              // gaussian-like falloff
    sum += t.src.sample(t.smp, uv + o * px) * w;
    wsum += w;
  }
  return sum / wsum;
}
