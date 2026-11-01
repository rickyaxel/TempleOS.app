// Array operations: fill, sieve, and a bubble-ish pass over an array.
I64 a[4096],i,j,sum=0; U8 *sieve=CAlloc(200000);
for (i=0;i<4096;i++) a[i]=(i*7919)%4096;
for (j=0;j<60;j++)
  for (i=1;i<4096;i++)
    if (a[i-1]>a[i]) { sum=a[i]; a[i]=a[i-1]; a[i-1]=sum; }
for (i=2;i<200000;i++)
  if (!sieve[i])
    for (j=i*2;j<200000;j+=i) sieve[j]=1;
sum=0;
for (i=2;i<200000;i++) if (!sieve[i]) sum++;
Free(sieve);
"%d %d\n",a[0],sum;
