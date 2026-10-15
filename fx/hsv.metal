// jet_hsv: shift hue, scale saturation and value.
//   hue         shift in degrees (0 = unchanged)
//   saturation  1 = unchanged, 0 = grey
//   value       1 = unchanged, 0 = black
// @input src
// @param float hue = 0
// @param float saturation = 1
// @param float value = 1

float3 rgb2hsv(float3 c)
{
  float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
  float4 q = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
  float4 r = c.r < q.x ? float4(q.xyw, c.r) : float4(c.r, q.yzx);
  float d = r.x - min(r.w, r.y);
  float e = 1.0e-10;
  return float3(abs(r.z + (r.w - r.y) / (6.0 * d + e)), d / (r.x + e), r.x);
}

float3 hsv2rgb(float3 c)
{
  float3 k = fract(float3(1.0, 2.0 / 3.0, 1.0 / 3.0) + c.x);
  float3 pp = abs(k * 6.0 - 3.0);
  return c.z * mix(float3(1.0), clamp(pp - 1.0, 0.0, 1.0), c.y);
}

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float4 c = t.src.sample(t.smp, uv);
  float3 hsv = rgb2hsv(c.rgb);
  hsv.x = fract(hsv.x + p.hue / 360.0);
  hsv.y = clamp(hsv.y * p.saturation, 0.0, 1.0);
  hsv.z = hsv.z * p.value;
  return float4(hsv2rgb(hsv), c.a);
}
