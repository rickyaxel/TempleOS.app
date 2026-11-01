//An empty char constant before an expression prints the expression as
//characters (Compiler/PrsExp.HC PrsFunCall: "empty char signals PutChars
//with variable"; Doc/HolyC.DD "'' drv;"). Psalmody, MorseCode, MagicPairs
//and WordSearch use it.
I64 c='A';
'' c;
'' 'B'+1;
'*';
"\n";
//EXPECT:
//AC*
