//Logical operators and short circuiting. && and || short-circuit
//(Compiler/OptPass012.HC "Branches are expressed with short-circuit logic");
//^^ is logical xor (Doc/HolyC.DD precedence list). Results are 0/1.
I64 calls=0;
I64 Hit(I64 v)
{
  calls++;
  return v;
}
if (Hit(0) && Hit(1)) "and-true\n";
"%d\n",calls;
calls=0;
if (Hit(1) || Hit(1)) "or-true\n";
"%d\n",calls;
calls=0;
"%d\n",Hit(2) ^^ Hit(0);
"%d\n",calls;
"%d %d %d %d\n",5&&3,0||7,5^^3,0^^0;
"%d %d\n",!5,!!5;
I64 z=0;
"%d\n",z && 1/z;
"%d\n",!z || 1/z;
I64 i=0;
while (i<5 && Hit(i)>=0)
  i++;
"%d %d\n",i,calls;
//EXPECT:
//1
//or-true
//1
//1
//2
//1 1 0 0
//0 1
//0
//1
//5 7
