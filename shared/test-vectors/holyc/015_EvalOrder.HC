//TempleOS evaluates the right side of = before the target's side effects.
//The original graphics library relies on this (*dst++=*dst&mask|c).
I64 a[3]={1,2,3},*p=a;
*p++=*p*10;
"%d %d %d\n",a[0],a[1],a[2];
//EXPECT:
//10 2 3
