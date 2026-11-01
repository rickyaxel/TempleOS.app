I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*39+148)&255;
for(i=0;i<4096;i++) b1[i]=(i*195)&127;
b0[102]=0; b1[1195]=0;
try{x=WinBorder(0x395,s0);}catch{Fs->catch_except=TRUE;}
try{x=Arg(-0.0,1.5);}catch{Fs->catch_except=TRUE;}
try{x=Option(0x100000003,0x143);}catch{Fs->catch_except=TRUE;}
try{x=mp_cnt();}catch{Fs->catch_except=TRUE;}
try{x=GrRect(s0,0x25a,(-76),0xa,0x85);}catch{Fs->catch_except=TRUE;}
try{x=Round(-1e308);}catch{Fs->catch_except=TRUE;}
try{x=SettingsPush(s0,0x66af5802527afb7f);}catch{Fs->catch_except=TRUE;}
try{x=ToF64(0x3fffffff);}catch{Fs->catch_except=TRUE;}
try{x=ScanKey(b1,NULL,0x3917b9ae528d81dc);}catch{Fs->catch_except=TRUE;}
try{x=IsMute();}catch{Fs->catch_except=TRUE;}
try{StrCpy(b1+2316,(b1+4096-2));}catch{Fs->catch_except=TRUE;}
try{x=StrPrintJoin(b1,"C:/Home/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",0x40000000,s0);}catch{Fs->catch_except=TRUE;}
try{Free(b1);}catch{Fs->catch_except=TRUE;}
try{p=MStrPrint("%lld%%tab",0x18,b0+0xc6cd53761935cfa,(-2));}catch{Fs->catch_except=TRUE;}
try{MemSetU32(NULL,0xfff,0xfff);}catch{Fs->catch_except=TRUE;}
try{x=WinDerivedValsUpdate(Fs);}catch{Fs->catch_except=TRUE;}
try{x=TaskValidate((b1+4096-0));}catch{Fs->catch_except=TRUE;}
try{x=Print("ab",b0,Fs,(-47));}catch{Fs->catch_except=TRUE;}
try{x=*(b1+2401)(I64*);}catch{Fs->catch_except=TRUE;}
try{x=JobQue(0x3074d68f187797e3,0x20000000,(-7980645521552926137),0x6d,0x180000000,Fs,0x100000011,0x8);}catch{Fs->catch_except=TRUE;}
try{x=ExePrint("%dabab",NULL);}catch{Fs->catch_except=TRUE;}
try{x=Tan(1e308);}catch{Fs->catch_except=TRUE;}
try{x=Btr(NULL,0x57);}catch{Fs->catch_except=TRUE;}
try{x=Str2I64(Fs,0xf);}catch{Fs->catch_except=TRUE;}
try{x=SysFont();}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
