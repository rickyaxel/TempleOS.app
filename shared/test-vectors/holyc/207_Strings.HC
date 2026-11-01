//Kernel/StrA.HC _STRCMP/_STRICMP/_STRNCMP return exactly 1 or -1 (MOV RAX,1 /
//MOV RAX,-1), never a character difference.
//Kernel/StrA.HC _STRCPY: a NULL src stores a single 0 (XOR RAX,RAX; STOSB), so
//StrCpy(buf,NULL) yields "" and does not fault.
//Kernel/StrA.HC StrUtil honours SUF_REM_LEADING/REM_TRAILING/SINGLE_SPACE/
//REM_SPACES; the runtime prelude (shared/runtime/Prelude.HC StrUtil) only
//implements SUF_TO_UPPER/SUF_TO_LOWER.
//Kernel/StrA.HC LstMatch: a needle that is a prefix of one entry returns that
//entry (unless LMF_EXACT), of several entries returns -2 (ambiguous); the
//prelude LstMatch only does exact matches.
//Kernel/StrScan.HC Str2I64: each '-' toggles the sign ("--5" is 5); runtimes
//return 0.
"%d %d %d\n",StrCmp("abc","ab"),StrCmp("b","a"),StrCmp("a","z");
"%d %d\n",StrICmp("abcd","AB"),StrNCmp("abcz","abca",4);
U8 su[64];
StrCpy(su,"  Hello   World  ");
StrUtil(su,SUF_REM_LEADING|SUF_REM_TRAILING|SUF_SINGLE_SPACE);
"[%s]\n",su;
StrCpy(su," a b c ");
StrUtil(su,SUF_REM_SPACES);
"[%s]\n",su;
"%d %d %d\n",LstMatch("c","a\0bb\0ccc\0"),LstMatch("b","a\0bb\0bcc\0"),LstMatch("b","a\0bb\0bcc\0",LMF_EXACT);
"%d\n",Str2I64("--5");
U8 buf[8];
StrCpy(buf,"xyz");
StrCpy(buf,NULL);
"[%s]\n",buf;
//EXPECT:
//1 1 -1
//1 1
//[Hello World]
//[abc]
//2 -2 -1
//5
//[]
