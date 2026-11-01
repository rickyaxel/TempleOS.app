//Loops, break (innermost loop only), goto (forward, backward, out of
//nested loops), if/else chains. HolyC has no continue (Doc/HolyC.DD:
//"There is no continue stmt. Use goto."), so it is not used here.
I64 i,j,cnt=0;
for (i=0;i<3;i++)
  for (j=0;j<3;j++) {
    if (j==2) break;
    cnt++;
  }
"%d\n",cnt;
i=0;
while (TRUE) {
  if (++i>=4) break;
}
"%d\n",i;
i=10;
do {
  i++;
} while (i<5);
"%d\n",i;
for (;;) {
  i--;
  if (i<8) break;
}
"%d\n",i;
U0 Gt()
{
  I64 n=0;
again:
  n++;
  if (n<5) goto again;
  "%d\n",n;
  goto skip;
  "never\n";
skip:
  "skipped\n";
}
Gt;
U0 G2()
{
  I64 a,b;
  for (a=0;a<10;a++)
    for (b=0;b<10;b++)
      if (a*b==12) goto found;
  "none\n";
  return;
found:
  "%d %d\n",a,b;
}
G2;
i=0;
while (i++<3);
"%d\n",i;
I64 Sign(I64 v)
{
  if (v<0)
    return -1;
  else if (v>0)
    return 1;
  else
    return 0;
}
"%d %d %d\n",Sign(-5),Sign(0),Sign(9);
I64 total=0;
for (i=1;i<=100;i++) total+=i;
"%d\n",total;
U0 Skip()
{
  I64 k,seen=0;
  for (k=0;k<6;k++) {
    if (k&1) goto next;
    "%d",k;
next:
    seen++;
  }
  " %d\n",seen;
}
Skip;
//EXPECT:
//6
//4
//11
//7
//5
//skipped
//2 6
//4
//-1 0 1
//5050
//024 6
