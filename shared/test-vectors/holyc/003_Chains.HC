I64 age=15,x=5,i=7,j=9;
if (13<=age<20) "Teen-ager\n";
if (5<i<j+1<20) "chain ok\n";
if (!(0<=x<5)) "out\n";
I64 p=2,b0=2,b1=2,b2=2;
if (p==b0==b1==b2) "all equal\n";
b2=1;
if (!(p==b0==b1==b2)) "not equal\n";
//EXPECT:
//Teen-ager
//chain ok
//out
//all equal
//not equal
