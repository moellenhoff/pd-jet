// Video feedback: blends the input with a rotated, zoomed copy of this
// effect's own previous output (the same idea as jet_feedback).
// @input src
// @feedback
// @param float decay = 0.9
// @param float rotate = 1.5
// @param float zoom = 1

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float2 c = uv - 0.5;
  float ang = p.rotate * 0.0174533;
  float cs = cos(ang), sn = sin(ang);
  float2 r = float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs) * p.zoom + 0.5;
  float4 cur = t.src.sample(t.smp, uv);
  float4 prev = float4(0.0, 0.0, 0.0, 1.0);
  if(all(r >= 0.0) && all(r <= 1.0)) {
    prev = t.prev.sample(t.smp, r);
  }
  return mix(cur, prev, p.decay);
}
