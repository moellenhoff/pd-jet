// Mirrors the incoming texture into a kaleidoscope.
// @input src
// @param float segments = 6
// @param float rotation = 0
// @param float zoom = 1

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float aspect = p.resolution.x / p.resolution.y;
  float2 c = (uv - 0.5) * float2(aspect, 1.0);
  float a = atan2(c.y, c.x) + p.rotation * 0.0174533;
  float r = length(c) / max(p.zoom, 0.001);
  float seg = 6.2831853 / max(floor(p.segments), 1.0);
  a = a - seg * floor(a / seg);
  a = fabs(a - seg * 0.5);
  float2 d = float2(cos(a), sin(a)) * r;
  return t.src.sample(t.smp, d / float2(aspect, 1.0) + 0.5);
}
