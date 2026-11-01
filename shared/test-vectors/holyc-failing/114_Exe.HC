//FAILING on both runtimes: "#exe {} (compile-time code execution) is not
//supported by TempleOS Mobile". #exe{} + StreamPrint() is documented TempleOS
//(Doc/HolyC.DD, Doc/PreProcessor.DD) and is how __DATE__/__TIME__/__LINE__/
//__FILE__ are defined.
#exe {StreamPrint("I64 exe_val=%d;",6*7);};
"%d\n",exe_val;
//EXPECT:
//42
