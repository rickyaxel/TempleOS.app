//TempleOS compiles and runs top-level statements one at a time,
//so code executed early can define symbols used by later code.
"start\n";
ExePrint("I64 defined_at_runtime=42;");
"%d\n",defined_at_runtime;
//EXPECT:
//start
//42
