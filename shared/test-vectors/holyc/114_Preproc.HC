//Preprocessor: #define is a textual string substitution (Compiler/Lex.HC
//HTT_DEFINE_STR -> LexIncludeStr), #if/#ifdef/#ifndef/#else/#endif
//(Doc/PreProcessor.DD).
#define N 5
#define SUM 2+3
"%d %d\n",N*2,SUM*2;
#ifdef N
"N defined\n";
#else
"N undefined\n";
#endif
#ifndef NOPE
"NOPE undefined\n";
#else
"NOPE defined\n";
#endif
#if N>3
"big\n";
#else
"small\n";
#endif
#if 0
"dead\n";
#endif
#define STR "text"
"%s\n",STR;
//EXPECT:
//10 8
//N defined
//NOPE undefined
//big
//text
