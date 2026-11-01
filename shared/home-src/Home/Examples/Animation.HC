//Animation with a draw_it callback, the standard TempleOS technique:
//the window manager calls DrawIt 30 times a second.

F64 t0;

U0 DrawIt(CTask *task,CDC *dc)
{
  F64 t=tS-t0;
  I64 i,x,y;
  for (i=0;i<12;i++) {
    x=task->pix_width/2+150*Cos(t+i*pi/6);
    y=task->pix_height/2+150*Sin(2*t+i*pi/6);
    dc->color=i+1;
    GrCircle(dc,x,y,10+5*Sin(t*3+i));
  }
  dc->color=BLACK;
  GrPrint(dc,8,8,"t=%5.2f  press a key to exit",t);
}

U0 Animation()
{
  t0=tS;
  SettingsPush;
  DocClear;
  Fs->draw_it=&DrawIt;
  GetChar(,FALSE);
  SettingsPop;
}

Animation;
