U8 buf[64];
StrPrint(buf,"%d-%s",7,"x");
"%s\n",buf;
U8 *m=MStrPrint("%d+%d=%d",2,2,4);
"%s %d\n",m,StrCmp(m,"2+2=4");
Free(m);
"%d %d\n",StrICmp("abc","ABC"),StrCmp("a","b")<0;
"%s\n",StrFind("lo","hello");
U8 *n=StrNew("copy");
StrCat(n,"");
"%s %d\n",n,MSize(n)>=5;
"%d\n",Str2I64("0x1F");
"%5.2f\n",Str2F64("3.25");
"%c\n",ToUpper('q');
"$$RED$$colored$$FG$$ text\n";
//EXPECT:
//7-x
//2+2=4 0
//0 1
//lo
//copy 1
//31
// 3.25
//Q
//colored text
