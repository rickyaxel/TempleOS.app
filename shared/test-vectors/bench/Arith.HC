// Arithmetic-heavy: integer and float math in a tight loop.
I64 i,acc=0; F64 f=0.0;
for (i=0;i<2000000;i++) {
  acc+=(i*7+3)%13-(i>>2)^(i&255);
  f+=i*0.5/(1.0+(i&7));
}
"%d %.3f\n",acc,f;
