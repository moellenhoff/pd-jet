// Inverts the colours of the incoming texture.
// @input src
// @param float amount = 1

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float4 c = t.src.sample(t.smp, uv);
  return float4(mix(c.rgb, 1.0 - c.rgb, p.amount), c.a);
}
