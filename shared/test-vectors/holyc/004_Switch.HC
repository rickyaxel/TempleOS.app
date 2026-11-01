I64 i;
for (i=0;i<12;i++)
  switch (i) {
    case: "Zero\n";	break;
    case: "One\n";	break;
    case: "Two\n";	break;
    case 5...7: "Range%d\n",i; break;
    case 10: "Ten\n";	break;
    case: "Eleven\n";	break;
  }
for (i=0;i<6;i++)
  switch (i) {
    case 0: "Zero ";	break;
    case 2: "Two ";	break;
    case 4: "Four ";	break;
    start:
      "[";
      case 1: "One";	break;
      case 3: "Three";break;
      case 5: "Five";	break;
    end:
      "] ";
      break;
  }
"\n";
switch [3] {
  case 3: "bracket\n"; break;
  default: "no\n";
}
//EXPECT:
//Zero
//One
//Two
//Range5
//Range6
//Range7
//Ten
//Eleven
//Zero [One] Two [Three] Four [Five] 
//bracket
