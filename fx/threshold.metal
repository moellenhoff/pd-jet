// jet_threshold: turns the picture into a black/white mask by brightness.
//   threshold  brightness above which a pixel becomes white
//   softness   width of the soft edge around the threshold (0 = hard)
//   keep       0 = white/black mask, 1 = keep the original colours where
//              the mask is white
// @input src
// @param float threshold = 0.5
// @param float softness = 0
// @param float keep = 0

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float4 c = t.src.sample(t.smp, uv);
  float lum = dot(c.rgb, float3(0.299, 0.587, 0.114));
  float s = max(p.softness, 0.0001);
  float m = smoothstep(p.threshold - s, p.threshold + s, lum);
  float3 rgb = p.keep > 0.5 ? c.rgb * m : float3(m);
  return float4(rgb, c.a);
}
