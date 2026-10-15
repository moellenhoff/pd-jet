// Row-based slit-scan: horizontal bands of the picture come from different
// moments, the delay growing from the top to the bottom.
//
//   maxdelay  how far back in time the last band reaches, in frames
//             (at most the @history length)
//   lines     how many bands the picture is cut into; 0 = no bands at all,
//             every pixel row gets its own delay
//   smooth    0 = each band shows one whole frame (steps),
//             1 = blend between neighbouring frames (no steps)
//   reverse   1 = the delay grows from the bottom to the top instead
// @input src
// @history 60
// @param float maxdelay = 40
// @param float lines = 40
// @param float smooth = 0
// @param float reverse = 0

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float row = p.reverse > 0.5 ? 1.0 - uv.y : uv.y;

  // 0..1 position along the delay axis, constant inside a band
  float pos = row;
  if(p.lines >= 1.0) {
    float n = floor(p.lines);
    float band = min(floor(row * n), n - 1.0);
    pos = n > 1.0 ? band / (n - 1.0) : 0.0;
  }

  float d = clamp(pos, 0.0, 1.0) * max(p.maxdelay - 1.0, 0.0);
  if(p.smooth > 0.5) {
    int a = int(floor(d));
    float f = d - float(a);
    return mix(jet_history(t, p, uv, a), jet_history(t, p, uv, a + 1), f);
  }
  return jet_history(t, p, uv, int(d + 0.5));
}
