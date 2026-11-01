U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello world",*p; I64 *q,x,i; F64 d;
for(i=0;i<256;i++) b0[i]=(i*155+95)&255;
try{x=DefinePrint("%h-1c%lld%.999999f",b0+210);}catch{Fs->catch_except=TRUE;}
