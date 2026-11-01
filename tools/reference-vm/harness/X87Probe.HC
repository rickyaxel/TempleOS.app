//X87Probe.HC: INSTRUMENTED PROBE, not a TempleOS program. Localizes the F64 differences found in
//Talons' CalcNormals (D3Unit, Kernel/KMathA.HC: x87 FSQRT and FDIVR on the 80-bit stack).
//Inputs are the synthetic-terrain cells where the reference VM and the app differed.

I64 XpB(F64 d)
{
  I64 b;
  MemCpy(&b,&d,8);
  return b;
}

U0 XpCell(I64 x,I64 y)
{
  CD3 p;
  F64 s,n,fx=x,fy=y,fz=-1;
  p.x=x; p.y=y; p.z=-1;
  D3Unit(&p);
  HPrint("XP cell %d %d D3Unit %016X %016X %016X\n",x,y,XpB(p.x),XpB(p.y),XpB(p.z));
  s=fx*fx+fy*fy+fz*fz;
  n=Sqrt(s);
  HPrint("XP cell %d %d s=%016X Sqrt=%016X x/n=%016X y/n=%016X z/n=%016X\n",x,y,XpB(s),XpB(n),
	XpB(fx/n),XpB(fy/n),XpB(fz/n));
  HPrint("XP cell %d %d onestack x/Sqrt(s)=%016X\n",x,y,XpB(fx/Sqrt(fx*fx+fy*fy+fz*fz)));
  p.x=x; p.y=y; p.z=-1;
  HPrint("XP cell %d %d D3Norm=%016X\n",x,y,XpB(D3Norm(&p)));
}

U0 XpMain()
{
  F64 two=2.0,three=3.0,one=1.0;
  HPrint("XP basic Sqrt(2)=%016X 1/3=%016X Sqrt(3)=%016X\n",XpB(Sqrt(two)),XpB(one/three),
	XpB(Sqrt(three)));
  XpCell(-10873,-1636);
  XpCell(4632,71);
  XpCell(-2311,-2230);
  XpCell(-9380,-459);
  HPrint("XP-END\n");
}

XpMain;
