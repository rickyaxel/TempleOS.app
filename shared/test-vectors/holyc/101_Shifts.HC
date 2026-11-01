//Shifts. Doc/HolyC.DD: I64 0x8000000000000000>>1 is 0xC000000000000000
//(arithmetic), U64 0x8000000000000000>>1 is 0x4000000000000000 (logical).
//BackA.HC ICShift picks SHR when the class is unsigned, else SAR.
//Variable shift counts use SHL/SAR r,CL which masks the count to 6 bits.
I64 neg=-16;
U64 un=0x8000000000000000;
"%d %X\n",neg>>2,un>>4;
"%X\n",neg(U64)>>60;
"%X\n",1<<63;
I64 sh=65;
"%d\n",1<<sh;
I64 one=1;
"%X\n",one<<sh;
I64 s64=64;
"%d\n",one<<s64;
I64 m1=-1;
"%d\n",m1>>s64;
U64 big=0xF000000000000000;
I64 four=4;
"%X\n",big>>four;
"%X\n",(-1)(U64)>>32;
"%d\n",-8>>1;
"%d\n",-1>>63;
"%X\n",0xFF<<8|0xFF;
U8 bt=0x81;
"%X\n",bt>>1;
I8 sbt=-127;
"%d\n",sbt>>1;
//EXPECT:
//-4 800000000000000
//F
//8000000000000000
//2
//2
//1
//-1
//F00000000000000
//FFFFFFFF
//-4
//-1
//FFFF
//40
//-64
