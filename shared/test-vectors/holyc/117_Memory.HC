//Heap and memory helpers. Kernel/Mem/MAllocFree.HC: MSize(NULL)=0, Free(NULL)
//is allowed (Doc/HolyC.DD), CAlloc zeroes, MAllocIdent copies MSize bytes.
//Kernel/KUtils.HC _MEMCMP returns -1/0/1.
U8 *p=MAlloc(10);
"%d %d\n",MSize(p)>=10,MSize(NULL);
Free(p);
Free(NULL);
"freed\n";
I64 *c=CAlloc(8*16);
I64 i,s=0;
for (i=0;i<16;i++) s+=c[i];
"%d\n",s;
Free(c);
U8 buf[16];
MemSet(buf,'x',5);
buf[5]=0;
"%s\n",buf;
MemSet(buf,'y',3);
"%s\n",buf;
MemCpy(buf,"abcdef",7);
"%s\n",buf;
"%d %d %d\n",MemCmp("abc","abd",3),MemCmp("abc","abc",3),MemCmp("b","a",1);
I64 *q=MAlloc(4*8);
MemSetI64(q,7,4);
"%d %d\n",q[0],q[3];
Free(q);
U8 *big=MAlloc(100000);
MemSet(big,1,100000);
s=0;
for (i=0;i<100000;i++) s+=big[i];
"%d %d\n",s,MSize(big)>=100000;
Free(big);
U8 *src=StrNew("ident");
U8 *cp=MAllocIdent(src);
"%s %d\n",cp,MSize(cp)==MSize(src);
Free(cp);
Free(src);
for (i=0;i<1000;i++) {
  p=MAlloc(1000);
  p[999]=1;
  Free(p);
}
"loop ok\n";
//EXPECT:
//1 0
//freed
//0
//xxxxx
//yyyxx
//abcdef
//-1 0 1
//7 7
//100000 1
//ident 1
//loop ok
