//String library semantics from Kernel/StrA.HC, Kernel/StrScan.HC,
//Kernel/StrPrint.HC, Kernel/Mem/MAllocFree.HC (StrNew).
//StrCmp/StrICmp/StrNCmp return exactly -1/0/1 (_STRCMP asm).
"%d %d\n",StrCmp("abc","abd"),StrCmp("","");
"%d %d\n",StrICmp("Hello","hELLO"),StrICmp("a","B");
"%d %d\n",StrNCmp("abcdef","abcxyz",3),StrNCmp("abc","abd",3);
"%d %d\n",StrLen(""),StrLen("hello world");
"%d\n",StrOcc("banana",'a');
"%s\n",StrFind("NA","banana",SFF_IGNORE_CASE);
"%d\n",StrFind("x","abc")==NULL;
"%s\n",StrMatch("an","banana");
U8 buf[64];
StrCpy(buf,"abc");
StrCat(buf,"def");
"%s %d\n",buf,StrLen(buf);
StrPrint(buf,"%d-%s-%c",12,"x",'Y');
CatPrint(buf,"+%d",3);
"%s\n",buf;
"%s\n",StrPrint(buf,"%03d",7);
U8 *m=MStrPrint("%s=%d","k",9);
"%s %d\n",m,StrLen(m);
Free(m);
U8 *n=StrNew("dup");
n[0]='D';
"%s\n",n;
Free(n);
n=StrNew(NULL);
"[%s] %d\n",n,StrLen(n);
Free(n);
U8 su[64];
StrCpy(su,"MiXeD");
"%s ",StrUtil(su,SUF_TO_UPPER);
"%s\n",StrUtil(su,SUF_TO_LOWER);
U8 fr[32],dst[32];
StrCpy(fr,"key=value=x");
StrFirstRem(fr,"=",dst);
"%s|%s\n",dst,fr;
StrCpy(fr,"a/b/c");
StrLastRem(fr,"/",dst);
"%s|%s\n",dst,fr;
"%s %s\n",StrFirstOcc("hello.world.txt","."),StrLastOcc("hello.world.txt",".");
"%d %d %d %d\n",Str2I64("  -42"),Str2I64("0b101"),Str2I64("ff",16),Str2I64("0x1F");
"%d %d %d\n",Str2I64("z",36),Str2I64("09"),Str2I64("12abc");
U8 *end;
Str2I64("123xyz",10,&end);
"%s\n",end;
"%s %d\n",LstSub(1,"a\0bb\0ccc\0"),LstSub(5,"a\0bb\0ccc\0")==NULL;
"%d %d\n",LstMatch("bb","a\0bb\0ccc\0"),LstMatch("z","a\0bb\0ccc\0");
"%d\n",LstMatch("BB","a\0bb\0",LMF_IGNORE_CASE);
"%c%c%c\n",ToUpper('a'),ToLower('Q'),ToUpper('5');
"ab" "cd\n";
"%X\n",'AB';
"%d\n",StrLen("a\tb\n");
"\x41\x42\n";
U8 *s="hello";
"%c %c %d\n",s[1],*(s+4),s[5];
//EXPECT:
//-1 0
//0 -1
//0 -1
//0 11
//3
//nana
//1
//anana
//abcdef 6
//12-x-Y+3
//007
//k=9 3
//Dup
//[] 0
//MIXED mixed
//key|value=x
//c|a/b
//.world.txt .txt
//-42 5 255 31
//35 9 12
//xyz
//bb 1
//1 -1
//1
//Aq5
//abcd
//4241
//4
//AB
//e o 0
