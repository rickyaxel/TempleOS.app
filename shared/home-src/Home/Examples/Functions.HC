//Functions: default arguments can appear anywhere and be skipped,
//and functions without arguments can be called without parentheses.

I64 Area(I64 w=10,I64 h)
{
  return w*h;
}

I64 Fib(I64 n)
{
  if (n<2) return n;
  return Fib(n-1)+Fib(n-2);
}

U0 Banner()
{
  "$$PURPLE$$-- TempleOS.app --$$FG$$\n";
}

Banner;
"Area(,4) = %d\n",Area(,4);
"Area(3,4) = %d\n",Area(3,4);
"Fib(20) = %d\n",Fib(20);
