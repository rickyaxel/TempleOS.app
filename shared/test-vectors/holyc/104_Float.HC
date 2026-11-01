//F64 arithmetic, int<->F64 conversion, Print of floats.
//F64->int conversions use FISTTP (truncate): Compiler/BackFA.HC ICFCvt.
//Round() uses FRNDINT in round-to-nearest-even mode: Kernel/KMathA.HC _ROUND.
//Varargs are passed raw, no int<->F64 conversion (Compiler/PrsExp.HC
//PrsFunCall only converts declared params), and ` always yields F64
//(OptPass012.HC IC_POWER), so "%d",2`10 prints the F64 bit pattern.
//Postfix typecasts reinterpret bits (Doc/HolyC.DD: use ToI64/ToF64 to convert).
F64 x=1.0/3;
"%.6f\n",x;
F64 y=10;
"%.1f\n",y/4;
I64 i=7;
F64 z=i/2;
"%.1f\n",z;
F64 w=i/2.0;
"%.1f\n",w;
F64 nf=-4.7;
I64 nk=nf;
"%d %d %d\n",nk,ToI64(-2.7),ToI64(3.99);
"%d %d %d %d\n",ToI64(Round(2.5)),ToI64(Round(3.5)),ToI64(Floor(-2.5)),ToI64(Ceil(-2.5));
"%d %d\n",ToI64(Trunc(-2.5)),ToI64(Round(-2.5));
"%.3f\n",Sqrt(2.0);
F64 sq=2`0.5;
"%.4f\n",sq;
F64 one=1.0;
"%X\n",one;
I64 bits=0x4000000000000000;
F64 two=bits(F64);
"%.1f\n",two;
F64 three=3.0;
I64 raw=three(I64);
"%X\n",raw;
if (0.1+0.2==0.3) "eq\n"; else "ne\n";
F64 fv=7.5;
"%.1f\n",fv%2;
fv=-7.5;
"%.1f\n",fv%2;
I64 ii=3;
F64 mixed=ii*0.5+1;
"%.2f\n",mixed;
F64 cmp=2.5;
if (cmp>2) "gt\n";
if (cmp<3) "lt\n";
"%.2f %.2f %.2f\n",Abs(-1.25),Max(1.5,2.5),Min(-1.0,0.5);
F64 ne=-0.0001;
"%.2f\n",ne;
F64 acc=0;
I64 k;
for (k=0;k<10;k++) acc+=0.1;
"%.10f\n",acc;
"%d\n",ToI64(ToF64(9007199254740993));
F64 big=I64_MAX;
"%d\n",big>1e18;
//EXPECT:
//0.333333
//2.5
//3.0
//3.5
//-4 -2 3
//2 4 -3 -2
//-2 -2
//1.414
//1.4142
//3FF0000000000000
//2.0
//4008000000000000
//ne
//1.5
//-1.5
//2.50
//gt
//lt
//1.25 2.50 -1.00
//-0.00
//1.0000000000
//9007199254740992
//1
