//AppIO.HC: the app-interpreter side of the harness I/O (counterpart of VmIO.HC, which the
//reference VM uses). Development/test file, never shipped. A harness file prints with HPrint;
//here the text is collected in memory and written to HARNESS_OUT by HEnd, and each line also goes
//to the console. ReferenceVmComparisonTest runs "#include AppIO.HC; #include <harness>; HEnd;".

#define HARNESS_OUT "C:/Home/HarnessOut.TXT"

U8 *h_out=NULL;
I64 h_out_len=0,h_out_size=0;

U0 HAppend(U8 *s,I64 n)
{
  U8 *b;
  if (h_out_len+n+1>h_out_size) {
    h_out_size=(h_out_len+n+1)*2;
    b=MAlloc(h_out_size);
    if (h_out) {
      MemCpy(b,h_out,h_out_len);
      Free(h_out);
    }
    h_out=b;
  }
  MemCpy(h_out+h_out_len,s,n);
  h_out_len+=n;
  h_out[h_out_len]=0;
}

U0 HPut(U8 *s)
{
  if (s) HAppend(s,StrLen(s));
}

U0 HPrint(U8 *fmt,...)
{
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv);
  HPut(buf);
  Free(buf);
}

U0 HProgress(I64 n)
{
  no_warn n;
}

I64 HCcMark()
{//No CCmpCtrl queue in the app (see VmIO.HC).
  return 0;
}

I64 HCcRestore(I64 mark)
{
  no_warn mark;
  return 0;
}

U0 HCapBegin()
{//The app has no StdOut hook: printed text is not captured (HCapEnd returns NULL).
}

U8 *HCapEnd()
{
  return NULL;
}

U8 *HData(U8 *name,I64 *_size=NULL)
{//Data files are placed in C:/Home/HData/ by the test.
  U8 buf[64],*res;
  StrPrint(buf,"C:/Home/HData/%s",name);
  res=FileRead(buf,_size);
  return res;
}

U0 HDataCd()
{//The test also puts data files that a harness #includes next to the harness files.
  Cd("C:/Home/Harness");
}

U0 HMemSnap(U8 *label)
{//The app's own accounting (MemUsed: bytes in use in the program's arena).
  HPrint("MEM %s app_mem_used=%d\n",label,MemUsed);
}

U64 Fnv64(U8 *b,I64 n,U64 h=0xCBF29CE484222325)
{//FNV-1a 64.
  while (n-->0) {
    h^=*b++;
    h*=0x100000001B3;
  }
  return h;
}

U0 HEnd()
{
  HPrint("HARNESS-DONE\n");
  FileWrite(HARNESS_OUT,h_out,h_out_len);
}
