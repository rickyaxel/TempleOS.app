//Each level keeps partial sums on the operand stack across the recursive
//call, so the operand stack overflows before the call-depth limit. Both
//runtimes must raise StkOver (never touch memory outside the stack).
I64 F(I64 n) {return 1+(2+(3+(4+(5+(6+(7+F(n+1)))))));}
"start\n";
F(0);
"unreachable\n";
//EXPECT-ERROR: StkOver
//EXPECT:
//start
