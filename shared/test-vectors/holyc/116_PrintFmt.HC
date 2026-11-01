//Print format codes. Expected strings derived by hand-porting
//Kernel/StrPrint.HC StrPrintJoin.
//Notes from the source: numbers ignore '-' (left justify is only used by
//OutStr for %s/%c/%p); %f with no precision prints 0 decimals and rounds via
//Round() (FRNDINT nearest-even); %e/%g/%n default to width 12 and truncate;
//%e recomputes the decimals from the width, so ".3" is ignored; 't' truncates
//(numbers keep the low digits); flags go AFTER width/precision ("%10,d").
"[%f][%f][%f][%f]\n",2.5,3.5,-2.5,0.5;
"[%.1f][%.2f][%.4f]\n",0.25,1.005,1.0/3;
"[%10.3f][%-10.3f][%010.3f]\n",-3.14159,2.71828,-1.5;
"[%e][%e][%e][%e]\n",1.0,0.00123,-98765.4321,0.0;
"[%15e][%.3e]\n",6.02214076e23,1234.5;
"[%g][%g][%g]\n",1234.5,0.0001234,1e20;
"[%g][%10.3g]\n",100.0,3.14159;
"[%n][%n][%n]\n",1234567.0,0.000123,-5.0;
"[%h?n][%16h?n]\n",12345.0,0.00123456789;
"[%10h?d][%10h3d][%10h?d]\n",123456789,123456789,12345;
"[%u][%d][%u]\n",-2,I64_MIN,0xFFFFFFFF;
"[%x][%X][%,X][%,b]\n",-1,0xDEADBEEF,0x123456789,0x1FF;
"[%8x][%-8X][%08X]\n",255,255,255;
"[%,d][%,d][%,d][%09,d][%10,d]\n",-1234567,999,1000,12345,-1234567;
"[%010,d][%,X]\n",-12345,0xABCDEF;
"[%5c][%-3c][%h3c][%h*c][%C]\n",'A','B','x',4,'y','hi';
"[%5ts][%-8s][%3s]\n","abcdefgh","ab","abcdef";
"[%z][%z]\n",0,"Apple\0Banana\0Cherry\0",2,"Apple\0Banana\0Cherry\0";
"[%5.1f][%.0f]\n",99.95,1e6;
"[%d][%x][%X]\n",0,0,0;
"[%3d][%-3d|][%03d]\n",12345,1,7;
"[%3td][%5td][%2tx]\n",12345,-42,0xABCD;
"[%f][%.2f]\n",1e18,1234567.891;
"%%|%5%|\n";
"[%c]\n",'Hello';
U8 *f="%d-%d\n";
"" f,1,2;
"[%*d][%.*f]\n",6,42,3,2.0;
//EXPECT:
//[2][4][-2][0]
//[0.2][1.00][0.3333]
//[    -3.142][     2.718][-00001.500]
//[1.00000000e0][1.2300000e-3][-9.8765432e4][0.00000000e0]
//[6.0221407600e23][1.23450000e3]
//[        1234][1.2340000e-4][1.0000000e20]
//[         100][     3.142]
//[1.23456700e6][123.00000e-6][-5.0000000e0]
//[12.34500000K][1.2345678900000m]
//[123.45679M][123456.79K][12.345000K]
//[18446744073709551614][-9223372036854775808][4294967295]
//[ffffffffffffffff][DEADBEEF][1,2345,6789][1,1111,1111]
//[      ff][      FF][000000FF]
//[-1,234,567][999][1,000][0,012,345][-1,234,567]
//[-0,012,345][AB,CDEF]
//[    A][B  ][xxx][yyyy][HI]
//[abcde][ab      ][abcdef]
//[Apple][Cherry]
//[100.0][1000000]
//[0][0][0]
//[12345][  1|][007]
//[345][  -42][cd]
//[1000000000000000000][1234567.89]
//%|%|
//[Hello]
//1-2
//[    42][2.000]
