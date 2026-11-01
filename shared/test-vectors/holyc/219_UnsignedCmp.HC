//Comparisons are unsigned if EITHER operand has ANY unsigned type, not just
//U64: Compiler/OptLib.HC OptFixupBinaryOp1 is_unsigned = tmpc1->raw_type&
//RTF_UNSIGNED || tmpc2->raw_type&RTF_UNSIGNED (RT_U8/U16/U32/U64 all have the
//bit); OptPass012.HC IC_LESS/IC_GREATER... set ICF_USE_UNSIGNED; BackB.HC then
//emits unsigned jumps. The runtimes only do this for U64.
I64 m1=-1;
U8 five=5;
if (m1<five) "lt\n"; else "ge\n";
U32 big=0xFFFFFFFF;
I64 neg=-5;
if (neg>big) "gt\n"; else "le\n";
U16 w=1;
if (m1>w) "gt\n"; else "le\n";
//EXPECT:
//ge
//gt
//gt
