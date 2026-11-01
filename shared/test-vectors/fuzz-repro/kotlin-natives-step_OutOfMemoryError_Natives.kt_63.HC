I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*45+190)&255;
for(i=0;i<4096;i++) b1[i]=(i*85)&127;
try{x=StrICmp("%p%tab",b1+1297);}catch{Fs->catch_except=TRUE;}
try{x=FramePtrDel(b0,b1);}catch{Fs->catch_except=TRUE;}
try{x=DocScroll(0x2);}catch{Fs->catch_except=TRUE;}
try{x=MemSet(Fs,0xa,0x1);}catch{Fs->catch_except=TRUE;}
try{x=Option((-1230884314674888132),0x40000001);}catch{Fs->catch_except=TRUE;}
try{x=CAlloc(0x5c,0x7fffffff);}catch{Fs->catch_except=TRUE;}
try{x=Sin(-0.0);}catch{Fs->catch_except=TRUE;}
try{x=StrPrintJoin(NULL,(b1+4096-3),0x1f,b0+269);}catch{Fs->catch_except=TRUE;}
try{Free(s0);}catch{Fs->catch_except=TRUE;}
try{x=StrNCmp("%lldab",b1,0xff);}catch{Fs->catch_except=TRUE;}
try{x=GrUsed();}catch{Fs->catch_except=TRUE;}
try{x=GrPlot(b0,0x431,0x34d);}catch{Fs->catch_except=TRUE;}
try{x=StrPrintJoin((-257958533982964558),"D:/x",0x40000000,s0);}catch{Fs->catch_except=TRUE;}
try{x=RandU16();}catch{Fs->catch_except=TRUE;}
try{x=GrFillTri0(b1+68,NULL,b1+3213,s0);}catch{Fs->catch_except=TRUE;}
try{x=StrNCmp(b0+0xff,s0,0x7fff);}catch{Fs->catch_except=TRUE;}
try{x=GrLineFat3(gr.dc,(-16),(-132),0xc1,0x463,0x34,(-115),0x237,0x55);}catch{Fs->catch_except=TRUE;}
try{x=DefineCnt(s0);}catch{Fs->catch_except=TRUE;}
try{x=Ln(-1e308);}catch{Fs->catch_except=TRUE;}
try{x=WinFocus(b1);}catch{Fs->catch_except=TRUE;}
try{x=GetTSC();}catch{Fs->catch_except=TRUE;}
try{x=Ln((-4)(F64));}catch{Fs->catch_except=TRUE;}
try{x=*(0x20000001)(I64*);}catch{Fs->catch_except=TRUE;}
try{x=DCTransform(s0,NULL,b0+215,Fs);}catch{Fs->catch_except=TRUE;}
try{x=Cos(-1e308);}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
