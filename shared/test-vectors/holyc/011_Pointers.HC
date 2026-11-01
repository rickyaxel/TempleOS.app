U0 Swap(I64 *a,I64 *b) {I64 t=*a; *a=*b; *b=t;}
I64 x=1,y=2;
Swap(&x,&y);
"%d %d\n",x,y;
U8 *p=MAlloc(16);
MemSet(p,'A',15); p[15]=0;
"%s\n",p;
Free(p);
I64 *big=CAlloc(8*100);
big[99]=7;
"%d %d\n",big[0],big[99];
Free(big);
class CNode {CNode *next; I64 v;};
CNode *head=NULL,*n;
I64 i;
for (i=0;i<5;i++) {n=MAlloc(sizeof(CNode)); n->v=i; n->next=head; head=n;}
for (n=head;n;n=n->next) "%d",n->v;
"\n";
//EXPECT:
//2 1
//AAAAAAAAAAAAAAA
//0 7
//43210
