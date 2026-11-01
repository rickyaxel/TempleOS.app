// String operations: formatting, copying, comparing, searching.
U8 buf[256],buf2[256]; I64 i,n=0;
for (i=0;i<40000;i++) {
  StrPrint(buf,"item %d of %X",i,i*3);
  StrCpy(buf2,buf);
  StrCat(buf2," tail");
  if (!StrCmp(buf,buf2)) n--;
  if (StrFind("of",buf2)) n++;
  n+=StrLen(buf2);
}
"%d\n",n;
