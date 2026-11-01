//EvalOrder.HC: INSTRUMENTED PROBE, not a TempleOS program. Order in which HolyC evaluates
//function arguments and binary-operator operands (found while comparing XCaliberPhysics.HC:
//PlaceShip calls ShipNew(RandU16%(..)+10,RandU16%(..)+10,type)).
//Each probe records the order of side effects as a digit string.

I64 eo_seq=0;

I64 EoNote(I64 tag)
{
  eo_seq=eo_seq*10+tag;
  return tag;
}

I64 EoTwo(I64 a,I64 b)
{
  return a*10+b;
}

I64 EoThree(I64 a,I64 b,I64 c)
{
  return a*100+b*10+c;
}

U0 EoMain()
{
  I64 r,c;
  F64 d;
  eo_seq=0; r=EoTwo(EoNote(1),EoNote(2));
  HPrint("EO args2 order=%d result=%d\n",eo_seq,r);
  eo_seq=0; r=EoThree(EoNote(1),EoNote(2),EoNote(3));
  HPrint("EO args3 order=%d result=%d\n",eo_seq,r);
  c=0; r=EoTwo(c++,c++);
  HPrint("EO args_postinc result=%d c=%d\n",r,c);
  eo_seq=0; r=EoNote(1)+EoNote(2);
  HPrint("EO add order=%d result=%d\n",eo_seq,r);
  eo_seq=0; r=EoNote(1)-EoNote(2)*EoNote(3);
  HPrint("EO sub_mul order=%d result=%d\n",eo_seq,r);
  eo_seq=0; d=EoNote(1)/ToF64(EoNote(2));
  HPrint("EO fdiv order=%d\n",eo_seq);
  eo_seq=0; r=EoNote(1)<EoNote(2);
  HPrint("EO cmp order=%d result=%d\n",eo_seq,r);
  eo_seq=0; r=EoNote(1)&&EoNote(2);
  HPrint("EO andand order=%d result=%d\n",eo_seq,r);
  eo_seq=0; HPrint("EO vararg_values %d %d\n",EoNote(1),EoNote(2));
  HPrint("EO vararg order=%d\n",eo_seq);
  eo_seq=0; r=EoNote(1); r=EoNote(2);
  HPrint("EO statements order=%d\n",eo_seq);
  HPrint("EO-END\n");
}

EoMain;
