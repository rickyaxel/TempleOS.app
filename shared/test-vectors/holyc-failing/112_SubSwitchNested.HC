//UNSUPPORTED (both runtimes): nested start:/end: groups give the compile error
//"nested start: blocks are not supported" (previously a host exception on Kotlin).
//Original analysis: Kotlin host ArrayIndexOutOfBoundsException (CodeGen.kt), Swift compile error.
//Compiler/PrsStmt.HC PrsSwitch keeps a queue of CSubSwitch (KW_START inside a
//start block goes back to sw_cont and pushes another one); every enclosing
//start block runs (IC_SUB_CALL, outermost first) before a case inside it, and a
//break jumps to the innermost group's end label.
I64 i;
for (i=0;i<7;i++)
  switch (i) {
    case 0: "z"; break;
    start:
      "<";
      case 1: "a"; break;
      case 2: "b"; break;
      start:
        "(";
        case 3: "c"; break;
        case 4: "d"; break;
      end:
        ")";
    end:
      ">";
      break;
    case 5: "f"; break;
  }
"\n";
//EXPECT:
//z<a><b><(c)><(d)>f
