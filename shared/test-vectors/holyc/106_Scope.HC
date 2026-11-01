//Globals, locals, parameters shadowing globals, static locals.
//Demo/GlblVars.HC: "Static vars are, essentually, global vars" (initialized once).
I64 g=1;
U0 SetG(I64 v) {g=v;}
U0 Shadow()
{
  I64 g=20;
  "local %d\n",g;
}
U0 Param(I64 g) {"param %d\n",g;}
Shadow;
Param(30);
"global %d\n",g;
SetG(5);
"global %d\n",g;
I64 Next()
{
  static I64 s=100;
  return s++;
}
"%d ",Next;
"%d ",Next;
"%d\n",Next;
U0 Counter()
{
  static I64 hits=0;
  I64 loc=0;
  hits++;
  loc++;
  "%d/%d ",hits,loc;
}
Counter; Counter; Counter;
"\n";
I64 Fact(I64 n)
{
  I64 local=n;
  if (n<=1) return 1;
  return local*Fact(n-1);
}
"%d\n",Fact(10);
U0 Arr()
{
  I64 a[3],j;
  for (j=0;j<3;j++) a[j]=j*j;
  "%d %d %d\n",a[0],a[1],a[2];
}
Arr;
//EXPECT:
//local 20
//param 30
//global 1
//global 5
//100 101 102
//1/1 2/1 3/1 
//3628800
//0 1 4
