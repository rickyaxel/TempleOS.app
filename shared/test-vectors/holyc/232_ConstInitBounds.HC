//Constant initializers are checked like any store: an initializer list longer
//than its zero-length array faults (a compile-time BadMem, reported as an
//invalid memory access) instead of writing past the arena.
"before\n";
U8 g[0][0x7FFFFF00]={{0},{65}};
"after\n";
//EXPECT-ERROR: invalid memory access
//EXPECT:
//before
