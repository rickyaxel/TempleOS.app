//(1) Any two comparison operators chain, not only < chains: Compiler/PrsExp.HC
//PE_POP_HIGHER adds ICF_PUSH_CMP whenever cur_op and stk_op are both IST_CMP,
//and Compiler/CInit.HC marks == != < > <= >= all IST_CMP. So 2<3==1 is
//2<3 && 3==1 -> 0.
//(2) ` is right associative: Compiler/CInit.HC d['`']=(PREC_EXP+ASSOCF_RIGHT);
//PrsExp.HC pushes instead of reducing for equal-precedence ASSOCF_RIGHT ops.
//2`2`3 = 2`(2`3) = 256 (SYS_POW in Kernel/KMathA.HC is exact for base 2).
//(3) Unary minus binds looser than `: PrsExp.HC PE_DO_UNARY_OP special case
//"cur_op==IC_POWER && stk_op==IC_UNARY_MINUS". -2`2 = -(2`2) = -4.
"%d\n",2<3==1;
I64 p;
p=2`2`3;
"%d\n",p;
p=-2`2;
"%d\n",p;
//EXPECT:
//0
//256
//-4
