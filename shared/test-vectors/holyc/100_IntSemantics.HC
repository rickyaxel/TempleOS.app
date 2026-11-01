//Integer types, wraparound and sign/zero extension.
//Doc/HolyC.DD: "All values are extended to 64-bit when accessed.
//Intermediate calculations are done with 64-bit values."
//I8/I16/I32 are sign-extended, U8/U16/U32 zero-extended on load.
//Limits from Kernel/KernelA.HH (I64_MAX, I64_MIN, U64_MAX).
I64 a=I64_MAX;
a++;
"%d\n",a;
"%d\n",I64_MIN-1;
U64 u=0;
u--;
"%u %X\n",u,u;
U8 b=250;
b+=10;
"%d\n",b;
I8 c=127;
c++;
"%d\n",c;
U16 w=0xFFFF;
w++;
"%d\n",w;
I16 s=-1;
"%d %X\n",s,s;
U32 d=0xFFFFFFFF;
"%d\n",d;
I32 e=0x7FFFFFFF;
e++;
"%d\n",e;
I64 big=3037000500;
"%d\n",big*big;
I64 mx=I64_MAX;
"%d\n",mx*2;
I64 mn=I64_MIN;
"%d\n",-mn;
U8 bytes[4];
bytes[0]=0x1FF;
bytes[1]=-1;
"%d %d\n",bytes[0],bytes[1];
I8 sb=0x80;
"%d\n",sb;
//U64 operand makes result class U64 (OptLib.HC OptFixupBinaryOp1: higher
//raw_type wins, RT_U64>RT_I64) so the divide is unsigned (BackA.HC ICDiv).
U64 ud=0xFFFFFFFFFFFFFFFE;
I64 three=3;
"%d\n",ud/three;
I64 m7=-7;
U64 u3=3;
"%u\n",m7/u3;
//Unary minus on unsigned gives the signed class (OptPass012.HC IC_UNARY_MINUS).
U64 five=5;
"%d\n",-five;
//Plain (non power of two) signed division truncates toward zero (x86 IDIV).
I64 n=-7,p=7,t3=3,mt3=-3;
"%d %d %d %d\n",n/t3,n%t3,p/mt3,p%mt3;
"%d %d\n",n/mt3,n%mt3;
//Constant folding uses signed I64 math (OptPass012.HC IC_DIV/IC_MOD).
"%d %d\n",-7/2,-7%2;
I64 cnt=0x10;
cnt<<=60;
"%X\n",cnt;
//EXPECT:
//-9223372036854775808
//9223372036854775807
//18446744073709551615 FFFFFFFFFFFFFFFF
//4
//-128
//0
//-1 FFFFFFFFFFFFFFFF
//4294967295
//-2147483648
//-9223372036709301616
//-2
//-9223372036854775808
//255 255
//-128
//6148914691236517204
//6148914691236517203
//-5
//-2 -1 -2 1
//2 -1
//-3 -1
//0
