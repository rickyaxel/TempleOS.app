//The 16 TempleOS colors.

U8 *names[16]={"BLACK","BLUE","GREEN","CYAN","RED","PURPLE","BROWN","LTGRAY",
  "DKGRAY","LTBLUE","LTGREEN","LTCYAN","LTRED","LTPURPLE","YELLOW","WHITE"};

U0 PaletteDemo()
{
  I64 i;
  CDC *dc=DCAlias;
  DocClear;
  for (i=0;i<16;i++) {
    dc->color=i;
    GrRect(dc,16+(i&3)*152,40+(i>>2)*100,140,60);
    dc->color=i^15;
    GrPrint(dc,24+(i&3)*152,64+(i>>2)*100,"%2d %s",i,names[i]);
  }
  "Press a key to exit.\n";
  GetChar(,FALSE);
  DCFill(dc);
  DCDel(dc);
}

PaletteDemo;
