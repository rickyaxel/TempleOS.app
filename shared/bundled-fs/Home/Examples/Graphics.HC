//Simple graphics with the original TempleOS graphics library.
//Press a key (or tap) to finish.

U0 GraphicsDemo()
{
  I64 i;
  CDC *dc=DCAlias;
  DocClear;
  "Press a key to exit.\n";
  for (i=0;i<16;i++) {
    dc->color=i;
    GrLine(dc,320,240,320+200*Cos(i*pi/8),240+200*Sin(i*pi/8));
  }
  dc->color=YELLOW;
  dc->thick=3;
  GrCircle3(dc,320,240,0,100);
  dc->color=LTRED;
  GrRect(dc,20,400,120,40);
  dc->color=WHITE;
  GrPrint(dc,32,416,"HolyC!");
  GetChar(,FALSE);
  DCFill(dc);
  DCDel(dc);
}

GraphicsDemo;
