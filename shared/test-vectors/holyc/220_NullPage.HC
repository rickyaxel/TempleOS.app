//TempleOS identity-maps low memory (Doc/MemOverview.DD): reading or writing
//through a NULL pointer plus an offset does not fault. On the reference VM,
//*NULL reads the BIOS interrupt vectors; TempleOS Mobile starts it zeroed.
//KeepAway's AI and TreeCheckers' game-over click read through NULL.
class CObj {I64 a,b; F64 get_ball_dt;};
CObj *o=NULL;
I64 *p=NULL;
p[10]=0x1234;
"%X %d\n",p[10],o->get_ball_dt==o->get_ball_dt;
try {
  I64 *far=0x7FFFFFFFFFF0;
  *far=1;
} catch {
  "outside %c\n",Fs->except_ch;
  Fs->catch_except=TRUE;
}
//EXPECT:
//1234 1
//outside BadMem
