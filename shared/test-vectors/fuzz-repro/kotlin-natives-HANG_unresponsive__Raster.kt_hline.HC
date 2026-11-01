I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*113+191)&255;
for(i=0;i<4096;i++) b1[i]=(i*162)&127;
try{MemSet(b1,0x1000,0xf8);}catch{Fs->catch_except=TRUE;}
try{MemSetI64(s0,0x1ffffffd,0x80000000);}catch{Fs->catch_except=TRUE;}
try{x=TextChar(NULL,0x484,0x3f,0x1b7,0x373);}catch{Fs->catch_except=TRUE;}
try{x=ASin(1e-320);}catch{Fs->catch_except=TRUE;}
try{x=Bt(b0+287,0x60180d7ca45b66e8); Bts(s0,0x1fffffff);}catch{Fs->catch_except=TRUE;}
try{x=MSize((b1+4096-11));}catch{Fs->catch_except=TRUE;}
try{x=Btr(Fs,0x8004);}catch{Fs->catch_except=TRUE;}
try{x=SettingsPop(b0+263,0xfb);}catch{Fs->catch_except=TRUE;}
try{x=Pow(1e308,0x7(F64));}catch{Fs->catch_except=TRUE;}
try{x=RandU32();}catch{Fs->catch_except=TRUE;}
try{x=GrFillTri0(b1+3372,(b1+4096-10),(b1+4096-4),s0);}catch{Fs->catch_except=TRUE;}
try{MemSetI64(b0+0x7fffffffffffffff,0x12e,0x2);}catch{Fs->catch_except=TRUE;}
try{x=Rand();}catch{Fs->catch_except=TRUE;}
try{x=0x7fffffff<<0x1ab; x=0xdc>>0x40000000; x=(0x18a)(U64)>>0x5;}catch{Fs->catch_except=TRUE;}
try{Print("ab",0x40000000,b1,0x20000001);}catch{Fs->catch_except=TRUE;}
try{StrCpy(b1+624,NULL);}catch{Fs->catch_except=TRUE;}
try{d=0x1f4(F64); x=d; x=ToI64(d*(-2));}catch{Fs->catch_except=TRUE;}
try{x=StrNCmp(b1,NULL,(-6639182354392229371));}catch{Fs->catch_except=TRUE;}
try{x=BFieldExtU32(0x132,0x1000,0x100000010);}catch{Fs->catch_except=TRUE;}
try{x=GrFillCircle(b0+0xd9,0x437,0x11,0x147,(-98));}catch{Fs->catch_except=TRUE;}
try{b1[0x20000000]=0x4a;}catch{Fs->catch_except=TRUE;}
try{x=DocCursor(0x4dc46d02d0399b6d,b0+0x1f);}catch{Fs->catch_except=TRUE;}
try{MemSetU16(Fs,0x31,0x4a);}catch{Fs->catch_except=TRUE;}
try{x=Bt(s0,(-2)); Bts(b1+1639,0x73abe25735c56935);}catch{Fs->catch_except=TRUE;}
try{x=0x180000000%0x1000; x=0x20000001/0x13b;}catch{Fs->catch_except=TRUE;}
"FUZZDONE\n";
