I64 Deep(I64 n) {return Deep(n+1);}
Deep(0);
//EXPECT-ERROR: StkOver
//EXPECT:
