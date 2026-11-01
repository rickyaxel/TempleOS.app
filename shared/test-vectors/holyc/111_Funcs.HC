//Functions: default args anywhere (Doc/HolyC.DD), skipped args f(,3), calls
//without parens, varargs argc/argv, extern prototypes (as in
//Compiler/OptPass012.HC "extern CIntermediateCode *OptBrNotZero(...)"),
//recursion, int<->F64 conversion for declared params (PrsExp.HC PrsFunCall
//ICF_RES_TO_F64 / ICF_RES_TO_INT; F64->int is FISTTP truncation).
U0 Test(I64 i=4,I64 j,I64 k=5) {"%d %d %d\n",i,j,k;}
Test(,3);
Test(1,2);
U0 Def(U8 *s="dflt",I64 n=2) {"%s %d\n",s,n;}
Def;
Def();
Def("x");
Def(,9);
I64 Sum(I64 first,...)
{
  I64 i,res=first;
  for (i=0;i<argc;i++)
    res+=argv[i];
  return res;
}
"%d %d\n",Sum(1),Sum(1,2,3,4);
I64 Cnt(...) {return argc;}
"%d %d\n",Cnt,Cnt(7,8,9);
F64 FSum(...)
{
  F64 r=0;
  I64 i;
  for (i=0;i<argc;i++)
    r+=argv[i](F64);
  return r;
}
"%.2f\n",FSum(1.25,2.5);
U0 PrintAll(U8 *fmt,...)
{
  U8 *b=StrPrintJoin(NULL,fmt,argc,argv);
  "[%s]\n",b;
  Free(b);
}
PrintAll("%d+%d",3,4);
extern I64 IsOdd(I64 n);
I64 IsEven(I64 n) {if (!n) return TRUE; return IsOdd(n-1);}
I64 IsOdd(I64 n) {if (!n) return FALSE; return IsEven(n-1);}
"%d %d %d\n",IsEven(10),IsOdd(7),IsOdd(4);
I64 Ack(I64 m,I64 n)
{
  if (!m) return n+1;
  if (!n) return Ack(m-1,1);
  return Ack(m-1,Ack(m,n-1));
}
"%d\n",Ack(2,3);
F64 Avg(F64 a,F64 b) {return (a+b)/2;}
"%.1f\n",Avg(3,4);
I64 Ident(I64 v) {return v;}
"%d %d\n",Ident(7.9),Ident(-7.9);
U0 Early(I64 n)
{
  if (n>0) {
    "pos\n";
    return;
  }
  "nonpos\n";
}
Early(1);
Early(0);
I64 Hanoi(I64 n) {if (!n) return 0; return 2*Hanoi(n-1)+1;}
"%d\n",Hanoi(20);
I64 SumTo(I64 n) {if (!n) return 0; return n+SumTo(n-1);}
"%d\n",SumTo(1000);
//EXPECT:
//4 3 5
//1 2 5
//dflt 2
//dflt 2
//x 2
//dflt 9
//1 10
//0 3
//3.75
//[3+4]
//1 1 0
//9
//3.5
//7 -7
//pos
//nonpos
//1048575
//500500
