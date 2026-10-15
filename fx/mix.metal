// jet_mix: blends the chain's texture (a) with a second texture (b).
// b is a named texture published with [jet_share name]: give the name as
// the creation argument ([jet_mix name]) or to the right inlet.
//   amount  0 = only a, 1 = only b (for the modes below it scales b)
//   mode    0 mix, 1 add, 2 multiply, 3 screen, 4 difference, 5 max, 6 min
// @input a
// @input b
// @param float amount = 0.5
// @param float mode = 0

float4 effect(float2 uv, constant JetParams &p, JetTex t)
{
  float4 a = t.a.sample(t.smp, uv);
  float4 b = t.b.sample(t.smp, uv);
  int m = int(p.mode + 0.5);
  float3 r;
  if(m == 1)      r = a.rgb + b.rgb * p.amount;
  else if(m == 2) r = mix(a.rgb, a.rgb * b.rgb, p.amount);
  else if(m == 3) r = mix(a.rgb, 1.0 - (1.0 - a.rgb) * (1.0 - b.rgb), p.amount);
  else if(m == 4) r = mix(a.rgb, abs(a.rgb - b.rgb), p.amount);
  else if(m == 5) r = mix(a.rgb, max(a.rgb, b.rgb), p.amount);
  else if(m == 6) r = mix(a.rgb, min(a.rgb, b.rgb), p.amount);
  else            r = mix(a.rgb, b.rgb, p.amount);
  return float4(clamp(r, 0.0, 1.0), a.a);
}
