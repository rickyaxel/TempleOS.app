I64 i=0,sum=0;
while (i<10) {
  i++;
  if (i==3) continue;
  if (i==8) break;
  sum+=i;
}
"%d %d\n",i,sum;
i=0;
do i+=3; while (i<10);
"%d\n",i;
U0 GotoTest()
{
  I64 j;
  for (j=0;;j++) if (j>4) goto done;
done:
  "goto %d\n",j;
}
GotoTest;
I64 a=5;
a+=2; a-=1; a*=3; a/=2; a%=5; a<<=3; a>>=1; a|=1; a&=~2; a^=8;
"%d\n",a;
F64 f=2;
f*=1.5; f+=1;
"%5.1f\n",f;
//EXPECT:
//8 25
//12
//goto 5
//25
//  4.0
