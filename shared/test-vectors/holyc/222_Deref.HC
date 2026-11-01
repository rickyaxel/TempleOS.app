//Dereferencing a non-pointer, as the original TempleOS does (reference VM, see
//docs/fidelity-audit/data/vm-observations.json): the value is the address and the
//read has the variable's own type (*I64 8 bytes, *I32 4 bytes sign-extended); a
//class variable's value is its first 8 bytes (ToTheFront's *indirect_head).
class Cq {I64 next,x;};
Cq cq;
U8 *b=MAlloc(16);
I64 i;
for (i=0;i<16;i++) b[i]=i+1;
b[3]=0x84;
I64 a=b;
I32 a32=b;
cq.next=b;
"%X %X\n",*a,*a32;
"%X\n",*cq;
//EXPECT:
//807060584030201 FFFFFFFF84030201
//807060584030201
