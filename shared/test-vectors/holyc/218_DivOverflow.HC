//x86 IDIV raises #DE when the quotient overflows (I64_MIN/-1, and I64_MIN%-1);
//TempleOS IntDivZero (Kernel/KInts.HC) turns every #DE into throw('DivZero').
//Runtimes return I64_MIN and 0 silently.
I64 mn=I64_MIN,neg1=-1;
try {
  "%d\n",mn/neg1;
} catch {
  "ovf %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  "%d\n",mn%neg1;
} catch {
  "ovfmod %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
//EXPECT:
//ovf DivZero
//ovfmod DivZero
