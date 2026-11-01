//` always produces an F64: Compiler/OptPass012.HC case IC_POWER sets
//tmpi->ic_class=cmp.internal_types[RT_F64] and converts both operands to F64;
//codegen calls SYS_POW (Kernel/KMathA.HC) which returns F64 bits.
//Varargs are pushed raw (Compiler/PrsExp.HC PrsFunCall only converts declared
//params), so %f sees 1024.0 and %d sees its bit pattern 0x4090000000000000.
"%f\n",2`10;
"%d\n",2`10;
"%X\n",2`3;
//EXPECT:
//1024
//4652218415073722368
//4020000000000000
