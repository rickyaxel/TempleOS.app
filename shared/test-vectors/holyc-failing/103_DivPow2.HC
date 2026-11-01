//FAILING on both runtimes (Kotlin + Swift). See verifier report.
//TempleOS compiler quirk: signed division by a constant power of two is
//compiled as an arithmetic shift (Compiler/OptPass012.HC IC_DIV: when the
//divisor is IC_IMM_I64 and Bsf(i)==Bsr(i) the op becomes IC_SHR_CONST, no
//signedness check; BackA.HC ICShift emits SAR for signed classes), so it
//rounds toward negative infinity. IC_MOD is only turned into AND when the
//class is unsigned, so % keeps IDIV semantics. For /= and %= the rewrite to
//SHR_EQU / AND_EQU happens regardless of sign (OptPass012.HC IC_DIV_EQU,
//IC_MOD_EQU).
I64 n=-7;
"%d %d %d\n",n/2,n/4,n%2;
I64 q=-7;
q/=2;
"%d\n",q;
I64 r=-7;
r%=4;
"%d\n",r;
I64 s=-7;
s/=3;
"%d\n",s;
I64 pos=7;
"%d %d\n",pos/2,pos%4;
//EXPECT:
//-4 -2 -1
//-4
//1
//-2
//3 3
