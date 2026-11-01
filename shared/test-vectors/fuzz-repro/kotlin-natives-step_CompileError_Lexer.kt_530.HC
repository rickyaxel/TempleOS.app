I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*231+142)&255;
for(i=0;i<4096;i++) b1[i]=(i*69)&127;
b0[137]=0; b1[3382]=0;
try{MemSet(Fs,0x1fffffff,(-317769933948161670));}catch{Fs->catch_except=TRUE;}
try{x=TaskDerivedValsUpdate(s0,0x3ffffffe);}catch{Fs->catch_except=TRUE;}
try{MemSetU32(b0,(-2),0x3645cca146fc4551);}catch{Fs->catch_except=TRUE;}
try{x=StrMatch(Fs,b0+0x40);}catch{Fs->catch_except=TRUE;}
try{x=IsSilent();}catch{Fs->catch_except=TRUE;}
try{x=BFieldExtU32(Fs,0x8000,0xffff);}catch{Fs->catch_except=TRUE;}
try{x=PutChars(0x7ffffffd);}catch{Fs->catch_except=TRUE;}
try{x=Cd(b0+0x10,0x180000000);}catch{Fs->catch_except=TRUE;}
try{x=BCnt(0x1c4);}catch{Fs->catch_except=TRUE;}
try{x=RandU32();}catch{Fs->catch_except=TRUE;}
try{x=Print(b0+0x3f);}catch{Fs->catch_except=TRUE;}
try{MemSet(Fs,0x100,0x3fffffff);}catch{Fs->catch_except=TRUE;}
try{x=Abs(1e-320);}catch{Fs->catch_except=TRUE;}
try{x=GrFillCircle(s0,0x2b5,0x11d,0x2c0,0x1b0);}catch{Fs->catch_except=TRUE;}
try{x=Arg((-5377076156057211871)(F64),-1e308);}catch{Fs->catch_except=TRUE;}
try{x=StrNCmp("%nab%10000000s","",0x1000);}catch{Fs->catch_except=TRUE;}
try{MemSetU32(0x100000010,0x7fffffff,0x10d);}catch{Fs->catch_except=TRUE;}
try{x=DirCur(b0,b0+20);}catch{Fs->catch_except=TRUE;}
try{x=Str2F64(b0+171,Fs);}catch{Fs->catch_except=TRUE;}
try{x=PopUpChoose(b0+(-7819611204401658904),b0,Fs,Fs,(b1+4096-8),0xfff);}catch{Fs->catch_except=TRUE;}
try{x=DocBottom();}catch{Fs->catch_except=TRUE;}
try{x=JobQue(0x171,0x351e4f7f571d5ae4,0x1004,0x47e713c388b3602b,0x1fe,NULL,0xffffffff,0xe);}catch{Fs->catch_except=TRUE;}
try{x=DefinePrint(b0+213,(b1+4096-12));}catch{Fs->catch_except=TRUE;}
try{b1[0x17a]=0x6a742aee1a5b783d;}catch{Fs->catch_except=TRUE;}
try{x=DocClear(NULL);}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
