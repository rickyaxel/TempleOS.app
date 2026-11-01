//An array dimension that is negative or too large is a compile error on both
//runtimes: its size used to wrap (Kotlin) or trap the whole app (Swift), and a
//constant initializer could then be written outside the program's memory.
"before\n";
U8 g[0][0xFFE613A8]={{0},{65}};
"after\n";
//EXPECT-ERROR: array dimension out of range
//EXPECT:
//before
