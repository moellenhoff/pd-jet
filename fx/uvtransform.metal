// jet_uvtransform: moves, turns and scales the PICTURE (not a shape):
//   translate  shift of the picture, in picture widths/heights (x right, y up)
//   rotate     degrees, counter-clockwise, around the centre
//   scale      2 = twice as big, 0.5 = half; a single number scales both
//   wrap       what shows outside the picture: 0 edge colour, 1 repeat,
//              2 mirror, 3 black
// @input src
// @param float2 translate = 0 0
// @param float rotate = 0
// @param float2 scale = 1 1
// @param float wrap = 0

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float aspect = p.resolution.x / p.resolution.y;
  float2 c = uv - 0.5;
  c -= float2(p.translate.x, -p.translate.y);
  c.x *= aspect;
  float a = -p.rotate * 0.0174533;
  c = float2(c.x * cos(a) - c.y * sin(a), c.x * sin(a) + c.y * cos(a));
  c /= float2(max(abs(p.scale.x), 0.0001), max(abs(p.scale.y), 0.0001));
  c.x /= aspect;
  float2 q = c + 0.5;
  int w = int(p.wrap + 0.5);
  if(w == 1) {
    q = fract(q);
  } else if(w == 2) {
    q = 1.0 - abs(fract(q * 0.5) * 2.0 - 1.0);
  } else if(w == 3) {
    if(any(q < 0.0) || any(q > 1.0)) return float4(0.0, 0.0, 0.0, 1.0);
  }
  return t.src.sample(t.smp, q);
}
