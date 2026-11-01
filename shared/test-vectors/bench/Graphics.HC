// Basic graphics operations on an off-screen device context.
CDC *dc=DCNew(640,480);
I64 i;
for (i=0;i<20000;i++) {
  dc->color=i&15;
  GrPlot(dc,i%640,i%480);
  GrLine(dc,i%640,0,639-i%640,479);
  if (!(i&31)) GrRect(dc,i%600,i%440,40,40);
}
"%d\n",GrPeek(dc,320,240);
DCDel(dc);
