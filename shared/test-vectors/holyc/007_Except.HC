U0 Inner()
{
  "inner\n";
  throw('Oops');
  "never\n";
}
try {
  Inner;
} catch {
  "caught %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  try {
    throw('Deep');
  } catch {
    "inner handler\n";
  }
} catch {
  "outer %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
I64 z=0;
try {
  "%d\n",5/z;
} catch {
  "div %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  I64 *bad=0x7FFFFFFFFFF0;
  *bad=5;
} catch {
  "mem %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
"after\n";
//EXPECT:
//inner
//caught Oops
//inner handler
//outer Deep
//div DivZero
//mem BadMem
//after
