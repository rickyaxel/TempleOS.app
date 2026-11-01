//Loops, branches and HolyC's chained comparisons.

I64 i,sum=0;
for (i=1;i<=10;i++)
  sum+=i;
"Sum of 1..10 is %d\n",sum;

i=0;
while (i<5) {
  if (1<=i<4)   //chained comparison: 1<=i && i<4
    "%d is between 1 and 3\n",i;
  i++;
}

for (i=0;i<6;i++)
  switch (i) {
    case 0: "zero ";	break;
    case 1...3: "small ";	break; //case ranges
    default: "big ";
  }
"\n";
