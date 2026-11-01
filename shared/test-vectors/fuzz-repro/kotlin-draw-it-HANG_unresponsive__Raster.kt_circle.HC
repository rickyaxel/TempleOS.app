I64 Cmp(I64 a,I64 b){return a-b;}
U8 *b0=MAlloc(256),*b1=MAlloc(4096),*s0="hello",*p; I64 *q,x,i; F64 d;
U0 DrawIt(CTask *task,CDC *dc){
  x=Copy((b1+4096-5),"%q$FG,99$");
  x=Sinh((0x7FF8000000000000)(F64));
  x=Arg(0x186(F64),1.5);
  x=Circle(b1+1493,0x2d,0x2,0x3f,0x1003,&Cmp,0x7ffffffe,(0x7FF8000000000000)(F64),(b1+4096-4));
  x=Str2I64(b0+18,0x40000001);
  x=AutoComplete(0x18d59d0b0e4e4737);
}
Fs->draw_it=&DrawIt; Sleep(200); "FUZZDONE\n";
