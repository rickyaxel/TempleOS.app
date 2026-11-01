I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*155+95)&255;
for(i=0;i<4096;i++) b1[i]=(i*199)&127;
try{x=TextLenAttr(NULL,0x43c,0x173,0x2cf,0x138);}catch{Fs->catch_except=TRUE;}
try{x=StrNCmp("ab%P$$FG$$%.-5f%b","%gabab",(-2));}catch{Fs->catch_except=TRUE;}
try{x=ATan(0x13(F64));}catch{Fs->catch_except=TRUE;}
try{x=GrFillTri0(b1,NULL,b0,b1+2008);}catch{Fs->catch_except=TRUE;}
try{x=*((b1+4096-0))(I64*);}catch{Fs->catch_except=TRUE;}
try{x=RegWrite(s0,b0);}catch{Fs->catch_except=TRUE;}
try{x=0xe%(-2); x=0x20000000/(-9032160999137337184);}catch{Fs->catch_except=TRUE;}
try{x=GrPeek(gr.dc,0x89,0xf3);}catch{Fs->catch_except=TRUE;}
try{p=MStrPrint("ab",0x3fffffff,b0+(-4931157066957103716),0x11b);}catch{Fs->catch_except=TRUE;}
try{x=GrFillTri0(gr.dc,b1,b0+59,Fs);}catch{Fs->catch_except=TRUE;}
try{x=FramePtrSet(Fs,0x1fffffff,b0+159);}catch{Fs->catch_except=TRUE;}
try{q=b1(I64*); q[0x1f7]=0x20000000;}catch{Fs->catch_except=TRUE;}
try{x=MemCmp(s0,0x7e31396bfdedce1d,0x59a17f75cc6b294);}catch{Fs->catch_except=TRUE;}
try{x=MemCmp(Fs,b1+122,(-9223372036854775803));}catch{Fs->catch_except=TRUE;}
try{x=DefineCnt(s0);}catch{Fs->catch_except=TRUE;}
try{x=StrLen(NULL);}catch{Fs->catch_except=TRUE;}
try{x=0x55ddf175a0ffa6d6<<0x40000000; x=0x4d>>0x20000000; x=(0x1)(U64)>>0x20000001;}catch{Fs->catch_except=TRUE;}
try{x=Bt(b1+3281,(-2)); Bts(s0,(-7105637022932667873));}catch{Fs->catch_except=TRUE;}
try{x=SettingsPush(b0+64,0x365ecb0432505ea1);}catch{Fs->catch_except=TRUE;}
try{x=Str2F64((b1+4096-4),b1);}catch{Fs->catch_except=TRUE;}
try{x=CAlloc(0x9f,Fs);}catch{Fs->catch_except=TRUE;}
try{x=Btc(b1,0xff);}catch{Fs->catch_except=TRUE;}
try{x=FramePtrAdd(Fs,0x160,Fs);}catch{Fs->catch_except=TRUE;}
try{x=SysTimerRead();}catch{Fs->catch_except=TRUE;}
try{x=ACos(1.5);}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
