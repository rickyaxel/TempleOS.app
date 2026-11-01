//Comparisons are unsigned if EITHER operand has an unsigned type
//(Compiler/OptLib.HC OptFixupBinaryOp1: is_unsigned = tmpc1 unsigned ||
//tmpc2 unsigned; OptPass012.HC IC_LESS etc. set ICF_USE_UNSIGNED;
//BackB.HC compare codegen then uses unsigned jumps).
I64 m1=-1;
U8 five=5;
U64 one=1;
I64 two=2;
if (m1<one) "lt\n"; else "ge\n";
if (m1<two) "lt\n"; else "ge\n";
I32 i32=-5;
I16 i16=3;
if (i32<i16) "slt\n"; else "sge\n";
//EXPECT:
//ge
//lt
//slt
