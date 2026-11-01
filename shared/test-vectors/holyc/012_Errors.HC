I64 *p=0x7FFFFFFFFFF0;
"before\n";
*p=1;
"after\n";
//EXPECT-ERROR: BadMem
//EXPECT:
//before
