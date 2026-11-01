//Classes, inheritance, unions, anonymous unions, nested members, offset().
//Members are packed with no alignment padding: Compiler/PrsVar.HC sets
//tmpm->offset=tmpc->size (and union_base for union members).
//Doc/HolyC.DD: only one base class; offset(class.member); sub-int access.
class CPacked
{
  U8 a;
  I64 b;
  U16 c;
};
"%d %d %d %d\n",offset(CPacked.a),offset(CPacked.b),offset(CPacked.c),sizeof(CPacked);
class CBase
{
  I64 id;
  U8 tag[4];
};
class CDerived : CBase
{
  I32 extra;
};
CDerived d;
d.id=7;
StrCpy(d.tag,"abc");
d.extra=-5;
"%d %s %d %d %d\n",d.id,d.tag,d.extra,sizeof(CDerived),offset(CDerived.extra);
CBase *bp=&d;
"%d\n",bp->id;
class CMix
{
  I64 head;
  union {
    U8 bytes[4];
    I32 word;
  };
  I64 tail;
};
"%d %d %d %d\n",offset(CMix.bytes),offset(CMix.word),offset(CMix.tail),sizeof(CMix);
CMix mx;
mx.word=0x04030201;
"%d %d\n",mx.bytes[0],mx.bytes[3];
union UF
{
  I64 i;
  F64 f;
  U8 b[8];
};
UF uf;
uf.f=1.0;
"%X %X %d\n",uf.i,uf.b[7],sizeof(UF);
class CPt
{
  I64 x,y;
};
CPt pts[3]={{1,2},{3,4},{5,6}};
"%d %d %d\n",pts[1].x,pts[2].y,sizeof(pts);
CPt *pp=pts;
pp+=2;
"%d\n",pp->x;
class CLine
{
  CPt a,b;
  U8 *name;
};
CLine ln;
ln.a.x=1;
ln.b.y=9;
ln.name="line";
CLine *lp=&ln;
"%d %d %s %d\n",lp->a.x,lp->b.y,lp->name,offset(CLine.name);
I64 v=0;
v.u8[1]=0x12;
v.i16[2]=-1;
"%X %d %d\n",v,v.i8[1],v.u16[2];
class COp
{
  I64 (*fn)(I64 a,I64 b);
};
I64 Add2(I64 a,I64 b) {return a+b;}
COp op;
op.fn=&Add2;
"%d\n",op.fn(2,3);
CPt *heap=MAlloc(sizeof(CPt)*2);
heap[1].y=77;
(heap+1)->x=66;
"%d %d\n",heap[1].x,heap[1].y;
Free(heap);
//EXPECT:
//0 1 9 11
//7 abc -5 16 12
//7
//8 8 12 20
//1 4
//3FF0000000000000 3F 8
//3 6 48
//5
//1 9 line 32
//FFFF00001200 18 65535
//5
//66 77
