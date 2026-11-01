//HolyC arithmetic. All integers are 64-bit.
//Note the operator precedence: << and >> bind tighter than * and /,
//and & | ^ bind tighter than + and -.

I64 a=17,b=5;
F64 x=2.5;

"a+b=%d a-b=%d a*b=%d a/b=%d a%%b=%d\n",a+b,a-b,a*b,a/b,a%b;
"2`10 (power operator) = %d\n",2`10;
"1<<4+1 = %d (shift binds tighter than +)\n",1<<4+1;
"x*x = %5.2f\n",x*x;
"Sqrt(2) = %9.6f\n",Sqrt(2);
"0x%X in hex, %b in binary\n",255,10;
