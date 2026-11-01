I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*153+142)&255;
for(i=0;i<4096;i++) b1[i]=(i*184)&127;
b0[48]=0; b1[2336]=0;
try{x=*(b1)(I64*);}catch{Fs->catch_except=TRUE;}
try{x=Msg(0x1ffffffc,0xc5,0x1ee,(-4035134263681334642));}catch{Fs->catch_except=TRUE;}
try{x=Move((b1+4096-9),b1+462);}catch{Fs->catch_except=TRUE;}
try{x=MStrPrint("%Pab%Z%h-1c$$FG$$");}catch{Fs->catch_except=TRUE;}
try{StrCpy(b0+49,b0+0xa6);}catch{Fs->catch_except=TRUE;}
try{x=Str2I64(b1+3475,(-2));}catch{Fs->catch_except=TRUE;}
try{x=Sinh(-1e308);}catch{Fs->catch_except=TRUE;}
try{x=SndFreq(0x40000001(F64));}catch{Fs->catch_except=TRUE;}
try{x=DocScroll(0xffffffff);}catch{Fs->catch_except=TRUE;}
try{x=MemUsed();}catch{Fs->catch_except=TRUE;}
try{x=GrPeek(b1,0x248,0x29c);}catch{Fs->catch_except=TRUE;}
try{x=Msg(0x40,0x117,0x1f8,0x7);}catch{Fs->catch_except=TRUE;}
try{x=Cos(1e-320);}catch{Fs->catch_except=TRUE;}
try{x=GrPlot1(gr.dc,0x439,0x116);}catch{Fs->catch_except=TRUE;}
try{x=DefinePrint(s0,b0);}catch{Fs->catch_except=TRUE;}
try{x=StrICmp(s0,b1+2987);}catch{Fs->catch_except=TRUE;}
try{x=MemSet(Fs,0x180000000,(-3));}catch{Fs->catch_except=TRUE;}
try{x=WinMax(b0+236);}catch{Fs->catch_except=TRUE;}
try{x=MemSet(Fs,0x7fffffff,0x10);}catch{Fs->catch_except=TRUE;}
try{x=ScanMsg(b1+3058,b1+481,"%Dab",0x20000005);}catch{Fs->catch_except=TRUE;}
try{x=StrLen((b1+4096-12));}catch{Fs->catch_except=TRUE;}
try{x=GrFillCircle(b1+1272,0x3fa,0xa8,0x215,0x376);}catch{Fs->catch_except=TRUE;}
try{x=Btc(b0,(-2037994661558389658));}catch{Fs->catch_except=TRUE;}
try{x=BFieldExtU32(b1+199,0x2782c8a711385ec9,0x1f);}catch{Fs->catch_except=TRUE;}
try{MemSetI64(b0,0x1,(-3602841852210097489));}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
