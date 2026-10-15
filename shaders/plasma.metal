// A generator (no input): slowly moving plasma in one colour.
// @param float speed = 0.5
// @param float scale = 4
// @param color tint = 1 0.6 0.3 1

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float2 q = uv * p.scale;
  float k = p.time * p.speed;
  float v = sin(q.x + k) + sin(q.y * 1.3 - k * 0.7) + sin((q.x + q.y) * 0.7 + k * 1.3);
  v = 0.5 + v / 6.0;
  return float4(p.tint.rgb * v, 1.0);
}
