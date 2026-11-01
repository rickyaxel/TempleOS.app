U0 Test(I64 i=4,I64 j,I64 k=5)
{
  Print("%X %X %X\n",i,j,k);
}
Test(,3);
Test(1,2,3);
I64 AddNums(...)
{
  I64 i,res=0;
  for (i=0;i<argc;i++)
    res+=argv[i];
  return res;
}
"%d\n",AddNums(1,2,3);
I64 Fib(I64 n) {if (n<2) return n; return Fib(n-1)+Fib(n-2);}
"%d\n",Fib(20);
I64 Twice(I64 x) {return 2*x;}
I64 (*fp)(I64 x)=&Twice;
"%d\n",fp(21);
U0 NoArgs() {"noargs\n";}
NoArgs;
F64 Half(F64 x) {return x/2;}
"%5.2f\n",Half(5);
//EXPECT:
//4 3 5
//1 2 3
//6
//6765
//42
//noargs
// 2.50
