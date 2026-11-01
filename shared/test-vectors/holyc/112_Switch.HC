//switch: ranges "case 4...7:", null cases (next higher int), fallthrough without break, default, nested switch.
//Doc/HolyC.DD, Demo/NullCase.HC, Demo/SubSwitch.HC.
U0 Classify(I64 i)
{
  switch (i) {
    case 1...3:
      "low ";
      break;
    case 4:
      "four ";
    case 5:
      "five-or-fall ";
      break;
    case 10...12:
      "ten-ish ";
      break;
    default:
      "other ";
  }
}
I64 i;
for (i=0;i<=13;i++) Classify(i);
"\n";
for (i=0;i<4;i++)
  switch (i) {
    case 0:
    case 1:
      "A";
      break;
    case 2:
      "B";
  }
"\n";
for (i=0;i<3;i++)
  switch (i) {
    case 0:
      switch (i+1) {
        case 1: "in1 "; break;
        default: "inX ";
      }
      "out0 ";
      break;
    default:
      "outD ";
  }
"\n";
I64 v=-2;
switch (v) {
  case -3...-1: "negrange\n"; break;
  default: "nope\n";
}
switch (100) {
  case 1: "one\n"; break;
}
"done\n";
//EXPECT:
//other low low low four five-or-fall five-or-fall other other other other ten-ish ten-ish ten-ish other 
//AAB
//in1 out0 outD outD 
//negrange
//done
