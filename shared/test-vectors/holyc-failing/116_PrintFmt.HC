//FAILING on both runtimes (Kotlin + Swift). See verifier report.
//(1) %p goes through Kernel/FunSeg.HC StrPrintFunSeg: an address with no symbol
//prints StrPrint("%X",addr) -> "0" for NULL; field width is applied by OutStr
//(right-justified); with the ',' flag it prints ".". Runtimes print 0x00000000.
//(2) Doc/HolyC.DD: "'' drv;" - an empty char const means PutChars() of a
//variable (Compiler/PrsExp.HC PrsFunCall: "empty char signals PutChars with
//variable"). Runtimes reject it as a compile error.
"[%p][%8p][%,p]\n",NULL,NULL,NULL;
I64 ch='Z';
'' ch;
'\n';
//EXPECT:
//[0][       0][.]
//Z
