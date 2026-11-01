//An uncaught DivZero must stop the program after output already produced.
//Kernel/KInts.HC IntDivZero throw('DivZero').
I64 z=0;
"before\n";
"%d\n",10/z;
"after\n";
//EXPECT-ERROR: DivZero
//EXPECT:
//before
