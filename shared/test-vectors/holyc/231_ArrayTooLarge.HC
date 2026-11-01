//A total array size above 2^31-1 bytes is a compile error, never a host trap.
"before\n";
I64 big[0x10000][0x10000];
"after\n";
//EXPECT-ERROR: array too large
//EXPECT:
//before
