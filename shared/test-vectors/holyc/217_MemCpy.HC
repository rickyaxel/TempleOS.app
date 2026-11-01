//Kernel/KUtils.HC _MEMSET / _MEMCPY end with "MOV RAX,RDI" after REP STOSB /
//REP MOVSB, so they return dst+cnt (not dst). REP MOVSB copies forward one
//byte at a time (CLD), so MemCpy(buf+1,buf,5) on "abcdef" replicates 'a'
//(the runtimes behave like memmove and give "aabcde").
U8 buf[16];
MemSet(buf,'x',5);
buf[5]=0;
U8 *r=MemSet(buf,'y',3);
"%d %s\n",r-buf,buf;
r=MemCpy(buf,"abcdef",7);
"%s %d\n",buf,r-buf;
StrCpy(buf,"abcdef");
MemCpy(buf+1,buf,5);
"%s\n",buf;
//EXPECT:
//3 yyyxx
//abcdef 7
//aaaaaa
