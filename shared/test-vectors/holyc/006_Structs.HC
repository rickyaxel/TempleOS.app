class CPt
{
  I64 x,y;
};
class CRect
{
  CPt a,b;
  U8 name[8];
};
CRect r;
r.a.x=1; r.a.y=2; r.b.x=30; r.b.y=40;
StrCpy(r.name,"box");
CRect *p=&r;
"%d %d %d %d %s %d\n",p->a.x,p->a.y,p->b.x,p->b.y,p->name,sizeof(CRect);
"%d\n",offset(CRect.b);
I64 v=0x123456780000DEF0;
v.u16[1]=0x9ABC;
"%X %X %X\n",v,v.u8[0],v.i32[1];
union U {I64 i; U8 b[8];};
U u; u.i=0x0102030405060708;
"%d %d\n",u.b[0],u.b[7];
I64 arr[3][4];
I64 i,j;
for (i=0;i<3;i++) for (j=0;j<4;j++) arr[i][j]=i*10+j;
"%d %d %d\n",arr[2][3],sizeof(arr),*(&arr[1][0]+2);
U8 *s="hello";
"%c%c %d\n",s[0],*(s+1),StrLen(s);
I64 ptrs[2]={10,20};
I64 *q=ptrs;
q++;
"%d %d\n",*q,q-ptrs;
//EXPECT:
//1 2 30 40 box 40
//16
//123456789ABCDEF0 F0 12345678
//8 1
//23 96 12
//he 5
//20 1
