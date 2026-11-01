I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*208+170)&255;
for(i=0;i<4096;i++) b1[i]=(i*64)&127;
try{x=MSize(b0);}catch{Fs->catch_except=TRUE;}
try{x=Trunc(1e308);}catch{Fs->catch_except=TRUE;}
try{x=Ln(-1e308);}catch{Fs->catch_except=TRUE;}
try{x=MemSetI64(b1,0x7,0x5e631f2168dd7f57);}catch{Fs->catch_except=TRUE;}
try{x=0x7ffffffffffffffc<<0x69c3d82312da9a1d; x=0x7>>(-2); x=(0x8)(U64)>>0xfff;}catch{Fs->catch_except=TRUE;}
try{x=MemSetI64(Fs,0x672b04bbf2fca880,(1<<63));}catch{Fs->catch_except=TRUE;}
try{x=BFieldExtU32(b0+(1<<63),0x40000002,0x3e);}catch{Fs->catch_except=TRUE;}
try{x=StrICmp("ababab",Fs);}catch{Fs->catch_except=TRUE;}
try{x=MemCmp(b1+2660,Fs,0x12);}catch{Fs->catch_except=TRUE;}
try{x=MsSet((-3933105125098941110),0x7ffffffffffffffe,0x1fffffff,0x7fffffff,0x46056c8e814e5e93);}catch{Fs->catch_except=TRUE;}
try{x=TaskValidate(Fs);}catch{Fs->catch_except=TRUE;}
try{x=BFieldExtU32(b1+3051,0x2,(-1060036490263507682));}catch{Fs->catch_except=TRUE;}
try{x=Mat4x4MulXYZ(b1+107,Fs,0x18b,Fs);}catch{Fs->catch_except=TRUE;}
try{p=MStrPrint("ab%abab",0x40,b0,(-9223372036854775807));}catch{Fs->catch_except=TRUE;}
try{x=Spaces((-7344919499588957566));}catch{Fs->catch_except=TRUE;}
try{Free(0x11a);}catch{Fs->catch_except=TRUE;}
try{x=Char2ScanCode(0x10000000f,(-8818940332112813929));}catch{Fs->catch_except=TRUE;}
try{x=MemSetI64(b0,0x7fffffffffffffff,0x7);}catch{Fs->catch_except=TRUE;}
try{x=GrHLine(s0,(-157),0x12e,(-148),0x8c,0x149);}catch{Fs->catch_except=TRUE;}
try{x=Tan(1e-320);}catch{Fs->catch_except=TRUE;}
try{x=GrPeek0(gr.dc,0x16f,(-27));}catch{Fs->catch_except=TRUE;}
try{x=ASin((0x7FF8000000000000)(F64));}catch{Fs->catch_except=TRUE;}
try{x=QSortI64(s0,0x7ffc,&Cmp);}catch{Fs->catch_except=TRUE;}
try{d=0x100000000(F64); x=d; x=ToI64(d*0x40000003);}catch{Fs->catch_except=TRUE;}
try{x=Bt(b1,0x104); Bts(Fs,0x5549a2aebfaf69af);}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
