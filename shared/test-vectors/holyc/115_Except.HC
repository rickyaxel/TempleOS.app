//try/catch/throw semantics from Kernel/KExcept.HC throw(): every enclosing
//catch{} runs, innermost first, until one sets Fs->catch_except=TRUE; then
//execution resumes after that try/catch. throw(I64 ch=0) takes up to 8 chars.
//StrPrintJoin throws 'StrPrint' when args run out (Kernel/StrPrint.HC).
U0 T1()
{
  try {
    throw('A');
  } catch {
    "c1 ";
  }
  "notreached ";
}
try {
  T1;
  "no ";
} catch {
  "c2 %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
"after1\n";
I64 k,caught=0;
for (k=0;k<5;k++) {
  try {
    if (k&1) throw('Odd');
    "k%d ",k;
  } catch {
    caught++;
    Fs->catch_except=TRUE;
  }
}
"caught %d\n",caught;
U0 Deep(I64 n)
{
  if (!n) throw('Bottom');
  Deep(n-1);
}
try {
  Deep(50);
} catch {
  "deep %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  throw;
} catch {
  "zero %d\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  throw('12345678');
} catch {
  "eight %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
try {
  "%d %d\n",1;
} catch {
  "fmt %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
I64 state=0;
U0 Mid()
{
  try {
    state=1;
    throw('Mid');
  } catch {
    state=2;
    if (Fs->except_ch=='Mid')
      Fs->catch_except=TRUE;
  }
  state=3;
}
Mid;
"state %d\n",state;
try {
  try {
    throw('In');
  } catch {
    "inner ";
    Fs->catch_except=TRUE;
  }
  "between ";
  throw('Out');
} catch {
  "outer %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
"end\n";
//EXPECT:
//c1 c2 A
//after1
//k0 k2 k4 caught 2
//deep Bottom
//zero 0
//eight 12345678
//fmt StrPrint
//state 3
//inner between outer Out
//end
