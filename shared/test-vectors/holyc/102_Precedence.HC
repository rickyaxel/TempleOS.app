//HolyC operator precedence differs from C. Compiler/CInit.HC cmp.binary_ops
//and Compiler/CompilerA.HH PREC_*: ` >> << (PREC_EXP) bind tighter than
//* / % (PREC_MUL), then &, then ^, then |, then + -, then < > <= >=,
//then == !=, then &&, then ^^, then ||, then assignment.
"%d\n",1+2<<3;
"%d\n",16>>2*2;
"%d\n",3|1+1;
"%d\n",6&3+1;
I64 x=4;
"%d\n",x&1==0;
"%d\n",5^3&1;
"%d\n",1|2^3;
"%d\n",2*3%4;
"%d\n",10-2-3;
"%d\n",100/10/5;
"%d\n",3>2>1;
//` is right associative (ASSOCF_RIGHT) and always yields F64 (OptPass012.HC
//IC_POWER), so convert before printing with %d. SYS_POW (Kernel/KMathA.HC) is
//exact for base 2 (FYL2X then FSCALE).
I64 p;
p=2`3*2;
"%d\n",p;
p=1+2`3;
"%d\n",p;
p=-2*-3;
"%d\n",p;
I64 a,b,c;
a=b=c=7;
"%d %d %d\n",a,b,c;
a=5;
a+=b*=2;
"%d %d\n",a,b;
"%d\n",~0;
"%d\n",!0+!5;
"%d\n",-~5;
"%d\n",1 ^^ 1 || 1 && 0;
//EXPECT:
//17
//8
//4
//3
//1
//4
//1
//2
//5
//2
//1
//16
//9
//6
//7 7 7
//19 14
//-1
//1
//6
//0
