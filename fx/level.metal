// jet_level: brightness, contrast and gamma of the current texture.
//   brightness  added to every channel (0 = unchanged)
//   contrast    1 = unchanged, 0 = flat grey, above 1 = harder
//   gamma       1 = unchanged, above 1 brightens the mid-tones
// @input src
// @param float brightness = 0
// @param float contrast = 1
// @param float gamma = 1

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float4 c = t.src.sample(t.smp, uv);
  float3 rgb = (c.rgb - 0.5) * p.contrast + 0.5 + p.brightness;
  rgb = pow(max(rgb, 0.0), 1.0 / max(p.gamma, 0.001));
  return float4(rgb, c.a);
}
