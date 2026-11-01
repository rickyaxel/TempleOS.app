//Integer division faults: x86 IDIV/DIV raise #DE for a zero divisor; TempleOS IntDivZero (Kernel/KInts.HC)
//turns #DE into throw('DivZero').
I64 z=0,one=1;
try {
  "%d\n",one/z;
} catch {
  "div %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  "%d\n",one%z;
} catch {
  "mod %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  I64 t=5;
  t/=z;
  "%d\n",t;
} catch {
  "diveq %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  U64 u=5;
  "%d\n",u/z;
} catch {
  "udiv %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
"alive\n";
//EXPECT:
//div DivZero
//mod DivZero
//diveq DivZero
//udiv DivZero
//alive
