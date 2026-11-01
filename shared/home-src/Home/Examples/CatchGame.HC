//A small game: move the paddle with the mouse (drag your finger) or
//the left/right arrow keys and catch the falling stars.

#define PADDLE_W 80
I64 paddle_x,star_x,star_y,score,missed;

U0 DrawIt(CTask *task,CDC *dc)
{
  dc->color=BLUE;
  GrRect(dc,paddle_x-PADDLE_W/2,task->pix_height-20,PADDLE_W,8);
  dc->color=YELLOW;
  GrCircle(dc,star_x,star_y,6);
  GrFloodFill(dc,star_x,star_y);
  dc->color=BLACK;
  GrPrint(dc,8,8,"Score:%d Missed:%d  (ESC to exit)",score,missed);
}

U0 CatchGame()
{
  I64 ch,sc;
  SettingsPush;
  DocClear;
  paddle_x=Fs->pix_width/2;
  star_x=RandU16%(Fs->pix_width-20)+10;
  star_y=0;
  Fs->draw_it=&DrawIt;
  while (TRUE) {
    if (ScanKey(&ch,&sc)) {
      if (ch==CH_ESC || ch==CH_SHIFT_ESC) break;
      if (sc.u8[0]==SC_CURSOR_LEFT)  paddle_x-=24;
      if (sc.u8[0]==SC_CURSOR_RIGHT) paddle_x+=24;
    }
    if (ms.lb) paddle_x=ms.pos.x-Fs->pix_left;
    paddle_x=ClampI64(paddle_x,PADDLE_W/2,Fs->pix_width-PADDLE_W/2);
    star_y+=4;
    if (star_y>=Fs->pix_height-20) {
      if (AbsI64(star_x-paddle_x)<PADDLE_W/2+6) {
	score++;
	Snd(70); Sleep(30); Snd;
      } else {
	missed++;
	Snd(40); Sleep(60); Snd;
      }
      star_x=RandU16%(Fs->pix_width-20)+10;
      star_y=0;
    }
    Sleep(20);
  }
  SettingsPop;
  "Final score: %d\n",score;
}

CatchGame;
