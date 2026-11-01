// Loop-heavy: nested loops with comparisons and a while loop.
I64 i,j,n=0;
for (i=0;i<1500;i++)
  for (j=0;j<1000;j++)
    if (i^j&1) n++;
i=0;
while (i<1000000) i+=3;
"%d %d\n",n,i;
