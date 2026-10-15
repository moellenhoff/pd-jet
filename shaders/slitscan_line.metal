// Row-based slit-scan: every horizontal line comes from a different
// moment, the delay growing from the top to the bottom of the picture.
// "reverse" 1 turns it around.
// @input src
// @history 40
// @param float maxdelay = 40
// @param float reverse = 0

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float row = p.reverse > 0.5 ? 1.0 - uv.y : uv.y;
  int delay = int(row * (p.maxdelay - 1.0) + 0.5);
  return jet_history(t, p, uv, delay);
}
