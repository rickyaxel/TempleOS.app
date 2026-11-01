//An outer zero dimension must not hide an oversized inner array type. The
//inner type's stride used to overflow before multiplication by zero on Swift.
"before\n";
U8 zero[0][0x40000000][0x40000000][16];
"after\n";
//EXPECT-ERROR: array too large
//EXPECT:
//before
