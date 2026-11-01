//TempleOS Mobile system prelude.
//Compiled before every program. Declares the TempleOS classes, globals and
//the host functions ("native") that form the complete capability surface of
//the sandbox. Class layouts and constants follow TempleOS V5.03 (public
//domain, Terry A. Davis); implementations are independent.

#include "PreludeDefines.HC"

#define TEXT_ROWS	60
#define TEXT_COLS	80
#define JIFFY_FREQ	1000
#define CNT_FREQ	1000000
#define ACf_INIT_IN_PROGRESS 0
#define SP_MOBILE	1
#define GR_SCALE	0x100000000 //32.32 fixed point (Doc/Transform.DD)
#define GR_PEN_BRUSHES_NUM 64
#define nan (0x7FF8000000000000(F64))

//---------------------------------------------------------------- data types
#include "KernelClasses.HC"

public class CGrGlbls
{//Layout of TempleOS V5.03 Adam/Gr/GrGlbls.HC (sprite_hash is opaque here).
  I64	*to_8_bits,*to_8_colors;
  CDC	*scrn_image,
	*dc,
	*dc1,
	*dc2,
	*dc_cache,
	*zoomed_dc;
  U32	*text_base;
  U16	*win_z_buf;
  I64	*sprite_hash;
  U16	*win_uncovered_bitmap;
  I64	highest_uncovered;
  U16	*vga_text_cache;
  I64	pan_text_x,pan_text_y;
  U0	(*fp_final_scrn_update)(CDC *dc);
  U0	(*fp_wall_paper)(CTask *task);
  U0	(*fp_draw_ms)(CDC *dc,I64 x,I64 y);
  U0	(*fp_draw_grab_ms)(CDC *dc,I64 x,I64 y,Bool closed);
  U8	*empty_sprite;
  CDC	*pen_brushes[GR_PEN_BRUSHES_NUM],
	*collision_pen_brushes[GR_PEN_BRUSHES_NUM],
	*even_pen_brushes[GR_PEN_BRUSHES_NUM],
	*odd_pen_brushes[GR_PEN_BRUSHES_NUM];
  I8	circle_lo[GR_PEN_BRUSHES_NUM][GR_PEN_BRUSHES_NUM],
	circle_hi[GR_PEN_BRUSHES_NUM][GR_PEN_BRUSHES_NUM];
  U8	*scrn_zoom_tables[9];
  I64	scrn_zoom,sx,sy;
  Bool	continuous_scroll,
	hide_row,hide_col;
};




public class CCntsGlbls
{
  I64	jiffies,
	timer,
	time_stamp_freq,
	time_stamp_kHz_freq,
	time_stamp_freq_initial;
};

//---------------------------------------------------------------- globals
CTask *Fs;
CTask *adam_task;
CMsStateGlbls ms;
CKbdStateGlbls kbd;
CGrGlbls gr;
CTextGlbls text;
CTask *sys_winmgr_task;
I64 sys_run_level;
CWinMgrGlbls winmgr;
CCntsGlbls cnts;
CAutoCompleteDictGlbls acd;
CScrnCastGlbls scrncast; //only .ona is kept (Snd, Kernel/KMisc.HC); no ScrnCast recording
CCPU *Gs;
CTask *sys_focus_task,*sys_task_being_scrn_updated;
U0 (*fp_update_ctrls)(CTask *task);
U0 (*fp_set_std_palette)();
I64 sys_semas[64];
U8 *sys_mobile_platform;

//---------------------------------------------------------------- console
native U0 PutChars(U64 ch);
native U0 PutS(U8 *st);
native U0 Print(U8 *fmt,...);
native U8 *StrPrintJoin(U8 *dst,U8 *fmt,I64 argc,I64 *argv);
native U8 *StrPrint(U8 *dst,U8 *fmt,...);
native U8 *CatPrint(U8 *_dst,U8 *fmt,...);
native U8 *MStrPrint(U8 *fmt,...);
native U0 DocClear(CTask *task=NULL);
native U0 DocBottom();
native U0 DocTop();
native U0 DocCursor(Bool show=OFF,CTask *task=NULL);
native U0 DocScroll(I64 cnt=1);
native U0 PutExceptMsg();
native U8 *SysPlatformName();
native U0 Raw(Bool val);

U0 PutExcept(Bool catch_it=TRUE)
{//Print exception msg and catch exception.
  "Except:%c:",Fs->except_ch;
  PutExceptMsg;
  "\n";
  Fs->catch_except=catch_it;
}


//---------------------------------------------------------------- memory
native U8 *MAlloc(I64 size,CTask *mem_task=NULL);
native U8 *CAlloc(I64 size,CTask *mem_task=NULL);
native U0 Free(U8 *addr);
native I64 MSize(U8 *src);
native I64 MSize2(U8 *src);
native U8 *MemCpy(U8 *dst,U8 *src,I64 cnt);
native U8 *MemSet(U8 *dst,I64 val,I64 cnt);
native U16 *MemSetU16(U16 *dst,I64 val,I64 cnt);
native U32 *MemSetU32(U32 *dst,I64 val,I64 cnt);
native I64 *MemSetI64(I64 *dst,I64 val,I64 cnt);
native I64 MemCmp(U8 *ptr1,U8 *ptr2,I64 cnt);
native I64 StrLen(U8 *st);
native I64 MemUsed();

public CDocEntry *DocPrint(CDoc *doc,U8 *fmt,...);

U8 *MAllocIdent(U8 *src,CTask *mem_task=NULL)
{
  U8 *res;
  I64 size;
  no_warn mem_task;
  if (!src) return NULL;
  size=MSize(src);
  res=MAlloc(size);
  MemCpy(res,src,size);
  return res;
}

//---------------------------------------------------------------- strings
U8 ToUpper(U8 ch)
{
  if ('a'<=ch<='z') return ch-'a'+'A';
  return ch;
}

U8 ToLower(U8 ch)
{
  if ('A'<=ch<='Z') return ch-'A'+'a';
  return ch;
}

U8 *StrCpy(U8 *dst,U8 *src)
{//As Kernel/StrA.HC _STRCPY: a NULL dst does nothing, a NULL src copies "".
  if (!dst) return dst;
  if (!src) {
    *dst=0;
    return dst;
  }
  MemCpy(dst,src,StrLen(src)+1);
  return dst;
}

U8 *StrCat(U8 *dst,U8 *src)
{
  MemCpy(dst+StrLen(dst),src,StrLen(src)+1);
  return dst;
}

U8 *StrNew(U8 *buf,CTask *mem_task=NULL)
{
  U8 *res;
  I64 size;
  no_warn mem_task;
  if (buf) {
    size=StrLen(buf)+1;
    res=MAlloc(size);
    MemCpy(res,buf,size);
  } else {
    res=MAlloc(1);
    *res=0;
  }
  return res;
}

native I64 StrCmp(U8 *st1,U8 *st2);
native I64 StrICmp(U8 *st1,U8 *st2);
native I64 StrNCmp(U8 *st1,U8 *st2,I64 n);
native I64 StrNICmp(U8 *st1,U8 *st2,I64 n);
native U8 *StrFind(U8 *needle,U8 *haystack_str,I64 flags=0);
native U8 *StrIMatch(U8 *needle,U8 *haystack_str);
native U8 *StrMatch(U8 *needle,U8 *haystack_str);
native I64 Str2I64(U8 *st,I64 radix=10,U8 **_end_ptr=NULL);
native F64 Str2F64(U8 *src,U8 **_end_ptr=NULL);

I64 StrOcc(U8 *src,U8 ch)
{
  I64 i=0;
  if (!src) return 0;
  while (*src)
    if (*src++==ch)
      i++;
  return i;
}

Bool IsWhiteSpaceCh(I64 ch)
{//Kernel/StrA.HC char_bmp_white_space: TAB, LF, CR, CH_SHIFT_SPACE, space.
  return ch==9 || ch==10 || ch==13 || ch==CH_SHIFT_SPACE || ch==CH_SPACE;
}

U8 *StrUtil(U8 *_src,I64 flags)
{//Modifies in place. Kernel/StrA.HC StrUtil (SUF_SAFE_DOLLAR and SUF_S2T not supported).
  U8 *src=_src,*dst=_src;
  I64 ch;

  if (flags & SUF_REM_LEADING)
    while (IsWhiteSpaceCh(*src))
      src++;
  while (ch=*src++)
    if (IsWhiteSpaceCh(ch)) {
      if (!(flags & SUF_REM_SPACES)) {
	if (flags & SUF_SINGLE_SPACE) {
	  *dst++ = CH_SPACE;
	  while ((ch=*src++) && IsWhiteSpaceCh(ch));
	  src--;
	} else
	  *dst++ = ch;
      }
    } else if (!(flags & SUF_REM_CTRL_CHARS) || ch>=CH_SHIFT_SPACE)
      *dst++=ch;
  *dst=0;

  if (flags & SUF_REM_TRAILING)
    while (dst!=_src && (!*dst || IsWhiteSpaceCh(*dst)))
      *dst-- =0;
  if (flags & SUF_TO_UPPER)
    for (dst=_src;*dst;dst++) {
      ch=*dst;
      if ('a'<=ch<='z')
	*dst=ch-0x20;
    }
  if (flags & SUF_TO_LOWER)
    for (dst=_src;*dst;dst++) {
      ch=*dst;
      if ('A'<=ch<='Z')
	*dst=ch+0x20;
    }
  return _src;
}

U8 *StrFirstOcc(U8 *src,U8 *marker)
{//Point to 1st occurrence of marker set in str. (TempleOS Kernel/StrA.HC)
  I64 ch;
  while ((ch=*src++) && !StrOcc(marker,ch));
  if (ch)
    return src-1;
  else
    return NULL;
}

U8 *StrFirstRem(U8 *src,U8 *marker,U8 *dst=NULL)
{//Remove first str segment and place in dst buf or NULL.
  I64 ch;
  U8 *ptr=src,*res=dst;
  if (dst) {
    while ((ch=*ptr++) && !StrOcc(marker,ch))
      *dst++=ch;
    *dst=0;
  } else
    while ((ch=*ptr++) && !StrOcc(marker,ch));
  if (ch)
    StrCpy(src,ptr);
  else
    *src=0;
  return res;
}

U8 *StrLastOcc(U8 *src,U8 *marker)
{//Point to last occurrence of marker set in str.
  I64 ch;
  U8 *res=NULL;
  while (ch=*src++)
    if (StrOcc(marker,ch))
      res=src-1;
  return res;
}

U8 *StrLastRem(U8 *src,U8 *marker,U8 *dst=NULL)
{//Remove last str segment and place in dst buf or NULL.
  U8 *ptr;
  if (ptr=StrLastOcc(src,marker)) {
    if (dst)
      StrCpy(dst,ptr+1);
    *ptr=0;
  } else {
    if (dst)
      StrCpy(dst,src);
    *src=0;
  }
  return dst;
}

U8 *LstSub(I64 sub,U8 *lst)
{//Point to list entry.
  if (!lst) return NULL;
  while (*lst && sub>0) {
    while (*lst++);
    sub--;
  }
  if (*lst) return lst;
  return NULL;
}

I64 LstMatch(U8 *needle, U8 *haystack_lst,I64 flags=0)
{//Kernel/StrA.HC LstMatch: -2 if ambiguous, -1 if not found. A unique prefix
//matches unless LMF_EXACT; '@' entries are aliases of the previous entry.
  I64 n,sub=0,res=-1;
  U8 *ptr;
  Bool exact_match=FALSE;
  if (!haystack_lst) return -1;
  n=StrLen(needle);
  while (*haystack_lst) {
    if (*haystack_lst=='@') {	//Check for '@' alias haystack_lst entry
      sub--;
      haystack_lst++;
    }
    ptr=needle;
    if (flags & LMF_IGNORE_CASE)
      while (*ptr && ToUpper(*ptr)==ToUpper(*haystack_lst)) {
	ptr++;
	haystack_lst++;
      }
    else
      while (*ptr && *ptr==*haystack_lst) {
	ptr++;
	haystack_lst++;
      }
    if (!*ptr) {		//Did we reach end of needle?
      if (!*haystack_lst)	//Did we reach end of haystack_lst?
	return sub;		//Found Exact match
      else {
	if (res!=-1) {
	  if (!exact_match)
	    res=-2;		//Ambiguous unless later exact match.
	} else {
	  if (!(flags & LMF_EXACT))
	    res=sub;
	}
      }
    }
    while (*haystack_lst)	//Advance to end of cur entry.
      haystack_lst++;
    haystack_lst++;		//Skip trailing zero
    sub++;
  }
  return res;
}

//---------------------------------------------------------------- math
native F64 Sin(F64 d);
native F64 Cos(F64 d);
native F64 Tan(F64 d);
native F64 ATan(F64 d);
native F64 ASin(F64 d);
native F64 ACos(F64 d);
native F64 Sinh(F64 d);
native F64 Cosh(F64 d);
native F64 Tanh(F64 d);
native F64 Arg(F64 x,F64 y);
native F64 Sqrt(F64 d);
native F64 Exp(F64 d);
native F64 Ln(F64 d);
native F64 Log2(F64 d);
native F64 Log10(F64 d);
native F64 Pow(F64 base,F64 power);
native F64 Pow10(F64 d);
native F64 Floor(F64 d);
native F64 Ceil(F64 d);
native F64 Round(F64 d);
native F64 Trunc(F64 d);
native F64 Abs(F64 d);
native I64 ToI64(F64 d);
native F64 ToF64(I64 i);
native Bool ToBool(I64 i);
native F64 Rand();
native I16 RandI16();
native U16 RandU16();
native I32 RandI32();
native U32 RandU32();
native I64 RandI64();
native U64 RandU64();
native I64 Seed(I64 seed=0,CTask *task=NULL);
native Bool Bt(U8 *bit_field,I64 bit);
native Bool Bts(U8 *bit_field,I64 bit);
native Bool Btr(U8 *bit_field,I64 bit);
native Bool Btc(U8 *bit_field,I64 bit);
native I64 Bsf(I64 bit_field_val);
native I64 Bsr(I64 bit_field_val);
native I64 BCnt(I64 d);
native U32 BFieldExtU32(U8 *bit_field,I64 bit,I64 size);
native U0 BFieldOrU32(U8 *bit_field,I64 bit,U32 pattern);

Bool LBt(U8 *bit_field,I64 bit) {return Bt(bit_field,bit);}
Bool LBts(U8 *bit_field,I64 bit) {return Bts(bit_field,bit);}
Bool LBtr(U8 *bit_field,I64 bit) {return Btr(bit_field,bit);}
Bool LBtc(U8 *bit_field,I64 bit) {return Btc(bit_field,bit);}
U0 LBEqu(U8 *bit_field,I64 bit,Bool val)
{
  if (val) Bts(bit_field,bit);
  else Btr(bit_field,bit);
}
Bool BEqu(U8 *bit_field,I64 bit,Bool val)
{
  Bool res=Bt(bit_field,bit);
  if (val) Bts(bit_field,bit);
  else Btr(bit_field,bit);
  return res;
}

F64 Sqr(F64 d) {return d*d;}
I64 SqrI64(I64 i) {return i*i;}
U64 SqrU64(U64 i) {return i*i;}
I64 AbsI64(I64 i) {if (i<0) return -i; return i;}
I64 SignI64(I64 i) {if (i<0) return -1; if (i>0) return 1; return 0;}
F64 Sign(F64 d) {if (d<0) return -1.0; if (d>0) return 1.0; return 0.0;}
I64 MinI64(I64 n1,I64 n2) {if (n1<n2) return n1; return n2;}
I64 MaxI64(I64 n1,I64 n2) {if (n1>n2) return n1; return n2;}
U64 MinU64(U64 n1,U64 n2) {if (n1<n2) return n1; return n2;}
U64 MaxU64(U64 n1,U64 n2) {if (n1>n2) return n1; return n2;}
F64 Min(F64 n1,F64 n2) {if (n1<n2) return n1; return n2;}
F64 Max(F64 n1,F64 n2) {if (n1>n2) return n1; return n2;}
I64 ClampI64(I64 num,I64 lo,I64 hi)
{
  if (num<lo) return lo;
  if (num>hi) return hi;
  return num;
}
U64 ClampU64(U64 num,U64 lo,U64 hi)
{
  if (num<lo) return lo;
  if (num>hi) return hi;
  return num;
}
F64 Clamp(F64 d,F64 lo,F64 hi)
{
  if (d<lo) return lo;
  if (d>hi) return hi;
  return d;
}
I64 FloorI64(I64 num,I64 to)
{
  if (num>=0)
    return num-num%to;
  else {
    num++;
    return num-num%to-to;
  }
}
I64 CeilI64(I64 num,I64 to)
{
  if (num>=0) {
    num+=to-1;
    return num-num%to;
  } else {
    num+=to-1;
    return num-num%to-to;
  }
}
I64 RoundI64(I64 num,I64 to)
{
  return num-num%to;
}
U64 FloorU64(U64 num,U64 to) {return num-num%to;}
U64 CeilU64(U64 num,U64 to) {num+=to-1; return num-num%to;}
U64 ModU64(U64 *q,U64 d)
{
  U64 res=*q%d;
  *q/=d;
  return res;
}
I64 DivMod(I64 *q,I64 d)
{
  I64 res=*q%d;
  *q/=d;
  return res;
}
F64 Pow10I64(I64 i) {return Pow10(i);}
U0 SwapI64(I64 *n1,I64 *n2) {I64 t=*n1; *n1=*n2; *n2=t;}
U0 SwapU8(U8 *n1,U8 *n2) {U8 t=*n1; *n1=*n2; *n2=t;}
U0 SwapU16(U16 *n1,U16 *n2) {U16 t=*n1; *n1=*n2; *n2=t;}
U0 SwapU32(U32 *n1,U32 *n2) {U32 t=*n1; *n1=*n2; *n2=t;}
F64 Wrap(F64 theta,F64 base=-pi)
{//Returns angle in range [base,base+2*pi).
  F64 res=theta%(2*pi);
  if (res>=base+2*pi)
    res-=2*pi;
  else if (res<base)
    res+=2*pi;
  return res;
}
F64 LowPass1(F64 a,F64 y0,F64 y,F64 dt=1.0)
{//First order low pass filter
  dt=Exp(-a*dt);
  return y0*dt+y*(1.0-dt);
}


//---------------------------------------------------------------- vectors
CD3 *D3Equ(CD3 *dst,F64 x=0,F64 y=0,F64 z=0)
{
  dst->x=x; dst->y=y; dst->z=z;
  return dst;
}
CD3 *D3Zero(CD3 *dst) {return D3Equ(dst);}
CD3 *D3Copy(CD3 *dst,CD3 *src) {dst->x=src->x; dst->y=src->y; dst->z=src->z; return dst;}
CD3 *D3Add(CD3 *sum,CD3 *d1,CD3 *d2) {sum->x=d1->x+d2->x; sum->y=d1->y+d2->y; sum->z=d1->z+d2->z; return sum;}
CD3 *D3Sub(CD3 *diff,CD3 *d1,CD3 *d2) {diff->x=d1->x-d2->x; diff->y=d1->y-d2->y; diff->z=d1->z-d2->z; return diff;}
CD3 *D3Mul(CD3 *prod,F64 s,CD3 *d) {prod->x=s*d->x; prod->y=s*d->y; prod->z=s*d->z; return prod;}
CD3 *D3Div(CD3 *quot,CD3 *d,F64 s) {quot->x=d->x/s; quot->y=d->y/s; quot->z=d->z/s; return quot;}
CD3 *D3AddEqu(CD3 *sum,CD3 *d) {sum->x+=d->x; sum->y+=d->y; sum->z+=d->z; return sum;}
CD3 *D3SubEqu(CD3 *sum,CD3 *d) {sum->x-=d->x; sum->y-=d->y; sum->z-=d->z; return sum;}
CD3 *D3MulEqu(CD3 *sum,F64 s) {sum->x*=s; sum->y*=s; sum->z*=s; return sum;}
CD3 *D3DivEqu(CD3 *sum,F64 s) {sum->x/=s; sum->y/=s; sum->z/=s; return sum;}
F64 D3Dot(CD3 *d1,CD3 *d2) {return d1->x*d2->x+d1->y*d2->y+d1->z*d2->z;}
CD3 *D3Cross(CD3 *prod,CD3 *d1,CD3 *d2)
{
  prod->x=d1->y*d2->z-d1->z*d2->y;
  prod->y=d1->z*d2->x-d1->x*d2->z;
  prod->z=d1->x*d2->y-d1->y*d2->x;
  return prod;
}
F64 D3NormSqr(CD3 *d) {return d->x*d->x+d->y*d->y+d->z*d->z;}
F64 D3Norm(CD3 *d) {return Sqrt(D3NormSqr(d));}
F64 D3DistSqr(CD3 *d1,CD3 *d2) {return Sqr(d1->x-d2->x)+Sqr(d1->y-d2->y)+Sqr(d1->z-d2->z);}
F64 D3Dist(CD3 *d1,CD3 *d2) {return Sqrt(D3DistSqr(d1,d2));}
CD3 *D3Unit(CD3 *d)
{
  F64 n=D3Norm(d);
  if (n) D3DivEqu(d,n);
  return d;
}
I64 D3I32DistSqr(CD3I32 *p1,CD3I32 *p2) {return SqrI64(p1->x-p2->x)+SqrI64(p1->y-p2->y)+SqrI64(p1->z-p2->z);}
F64 D3I32Dist(CD3I32 *p1,CD3I32 *p2) {return Sqrt(D3I32DistSqr(p1,p2));}
I64 D3I32NormSqr(CD3I32 *p) {return SqrI64(p->x)+SqrI64(p->y)+SqrI64(p->z);}

//---------------------------------------------------------------- queues
U0 QueInit(CQue *head) {head->next=head->last=head;}
//TempleOS compiles QueIns/QueInsRev inline (Compiler/BackC.HC ICQueIns) and the
//entry ends up in RAX; returning it keeps programs that use that value working.
CQue *QueIns(CQue *entry,CQue *pred)
{
  CQue *succ=pred->next;
  entry->next=succ;
  entry->last=pred;
  pred->next=entry;
  succ->last=entry;
  return entry;
}
CQue *QueInsRev(CQue *entry,CQue *succ)
{
  CQue *pred=succ->last;
  entry->next=succ;
  entry->last=pred;
  pred->next=entry;
  succ->last=entry;
  return entry;
}
U0 QueRem(CQue *entry)
{
  CQue *next=entry->next,*last=entry->last;
  last->next=next;
  next->last=last;
}
U0 QueDel(CQue *head,Bool querem=FALSE)
{
  CQue *tmpq=head->next,*tmpq1;
  while (tmpq!=head) {
    tmpq1=tmpq->next;
    if (querem) QueRem(tmpq);
    Free(tmpq);
    tmpq=tmpq1;
  }
}
I64 QueCnt(CQue *head)
{
  I64 res=0;
  CQue *tmpq=head->next;
  while (tmpq!=head) {
    res++;
    tmpq=tmpq->next;
  }
  return res;
}
CQue *QueCopy(CQue *head,CTask *mem_task=NULL)
{
  CQue *res=MAlloc(sizeof(CQue)),*tmpq=head->next,*tmpq1;
  no_warn mem_task;
  QueInit(res);
  while (tmpq!=head) {
    tmpq1=MAllocIdent(tmpq);
    QueIns(tmpq1,res->last);
    tmpq=tmpq->next;
  }
  return res;
}

//---------------------------------------------------------------- sorting
native U0 QSortI64(I64 *base,I64 num,I64 (*fp_compare)(I64 e1,I64 e2));
native U0 QSort(U8 *base,I64 num,I64 width,I64 (*fp_compare)(U8 *e1,U8 *e2));

//---------------------------------------------------------------- time
native U0 Sleep(I64 mS);
native U0 Yield();
native U0 Refresh(I64 cnt=1,Bool force=FALSE);
native F64 tS();
native I64 GetTSC();
native CDate Now();
native U0 Busy(I64 uS);
native I64 SysTimerRead();

U0 Date2Struct(CDateStruct *_ds,CDate cdt)
{//Convert CDate to CDateStruct (proleptic Gregorian, TempleOS day 0 = 1/1/0).
  I64 z=cdt.date-60,era,doe,yoe,y,doy,mp,d,m,secs;
  if (z>=0) era=z/146097; else era=(z-146096)/146097;
  doe=z-era*146097;
  yoe=(doe-doe/1460+doe/36524-doe/146096)/365;
  y=yoe+era*400;
  doy=doe-(365*yoe+yoe/4-yoe/100);
  mp=(5*doy+2)/153;
  d=doy-(153*mp+2)/5+1;
  if (mp<10) m=mp+3; else m=mp-9;
  if (m<=2) y++;
  _ds->year=y;
  _ds->mon=m;
  _ds->day_of_mon=d;
  _ds->day_of_week=(cdt.date+6)%7;
  secs=(cdt.time(U64)*86400*10000)>>32;
  _ds->sec10000=secs%100;
  _ds->sec100=secs/100%100;
  secs/=10000;
  _ds->sec=secs%60;
  _ds->min=secs/60%60;
  _ds->hour=secs/3600;
}

//---------------------------------------------------------------- exceptions
native U0 throw(I64 ch=0,Bool no_log=FALSE);
native U0 Break();
native Bool BreakLock(CTask *task=NULL);
native Bool BreakUnlock(CTask *task=NULL);

//---------------------------------------------------------------- input
native I64 GetChar(I64 *_scan_code=NULL,Bool echo=TRUE,Bool raw_cursor=FALSE);
native I64 GetKey(I64 *_scan_code=NULL,Bool echo=FALSE,Bool raw_cursor=FALSE);
native Bool ScanKey(I64 *_ch=NULL,I64 *_scan_code=NULL,Bool echo=FALSE);
native I64 GetMsg(I64 *_arg1=NULL,I64 *_arg2=NULL,I64 mask=~1,CTask *task=NULL);
native I64 ScanMsg(I64 *_arg1=NULL,I64 *_arg2=NULL,I64 mask=~1,CTask *task=NULL);
native U0 FlushMsgs(CTask *task=NULL);
native I64 Char2ScanCode(I64 ch,I64 sc_flags=0);
native U8 ScanCode2Char(I64 sc);

public I64 ScanChar()
{//Checks for MSG_KEY_DOWN and returns 0 immediately if no key (Kernel/SerialDev/Message.HC).
//Waits for MSG_KEY_UP of non-zero ASCII key and returns ASCII if key.
  //ScanMsg() throws away other message types.
  I64 arg1a,arg2a,arg1b,arg2b;
  if (!ScanMsg(&arg1a,&arg2a,1<<MSG_KEY_DOWN)||!arg1a)
    return 0;
  else
    do GetMsg(&arg1b,&arg2b,1<<MSG_KEY_UP);
    while (!arg1b);  //Be careful of SC_SHIFT and SC_CTRL, etc.
  return arg1a;
}
//Reads a line like Adam/DolDoc/DocGet.HC DocGetStr2: ESC is ignored on a plain prompt,
//SHIFT-ESC returns "" (or ends the task with GSF_SHIFT_ESC_EXIT).
native U8 *MobileGetStr2(I64 flags=0);
native I64 ExePrint(U8 *fmt,...); //compile errors: printed, returns 0
native I64 ExePrint2(U8 *fmt,...); //compile errors: throws 'Compiler'
native U0 Msg(I64 msg_code,I64 arg1,I64 arg2,I64 flags=0);
native U0 MsSet(I64 x=I64_MAX,I64 y=I64_MAX,I64 z=I64_MAX,I64 l=I64_MAX,I64 r=I64_MAX);

I64 PressAKey()
{//Print "Press a key" and wait for non-zero ASCII key (Kernel/StrB.HC).
  "$$BK,1$$PRESS A KEY$$BK,0$$\n";
  return GetChar(,FALSE);
}

public U8 *GetStr(U8 *msg=NULL,U8 *dft=NULL,I64 flags=0)
{//Returns a MAlloc()ed prompted string (Kernel/SerialDev/Message.HC).
  U8 *st;
  if (msg)
    "" msg,dft;
  st=MobileGetStr2(flags);
  if (!*st) {
    Free(st);
    if (dft)
      return StrNew(dft);
    else
      return StrNew("");
  }
  return st;
}

public I64 GetS(U8 *buf,I64 size,Bool allow_ext=TRUE)
{//Prompt into fixed length string. Size must include terminator (Kernel/SerialDev/Message.HC).
  U8 *st;
  I64 ch,i=0;
  if (!size || !buf) return 0;
  if (allow_ext) {
    st=GetStr;
    if (StrLen(st)>size-1) {
      MemCpy(buf,st,size-1);
      buf[size-1]=0;
    } else
      StrCpy(buf,st);
    i=StrLen(buf);
    Free(st);
  } else {
    while (TRUE) {
      ch=GetChar(,FALSE);
      if (ch=='\n') {
	'' ch;
	break;
      } else if (ch==CH_BACKSPACE) {
	if (i>0) {
	  i--;
	  '' ch;
	}
      } else {
	if (i<size-1) {
	  buf[i++]=ch;
	  '' ch;
	}
      }
    }
    buf[i]=0;
  }
  return i;
}

public I64 GetI64(U8 *msg=NULL,I64 dft=0,I64 lo=I64_MIN,I64 hi=I64_MAX)
{//Prompt user for I64 expression (Adam/DolDoc/DocGet.HC).
  Bool okay;
  U8 *st;
  I64 res;
  while (TRUE) {
    if (msg)
      "" msg,dft;
    st=GetStr;
    if (!*st) {
      Free(st);
      return dft;
    }
    try {
      res=ExePrint2("ToI64(%s);",st);
      okay=TRUE;
    } catch {
      Fs->catch_except=TRUE;
      okay=FALSE;
    }
    Free(st);
    if (okay && lo<=res<=hi)
      return res;
  }
}

public F64 GetF64(U8 *msg=NULL,F64 dft=0,F64 lo=F64_MIN,F64 hi=F64_MAX)
{//Prompt user for F64 expression (Adam/DolDoc/DocGet.HC).
  Bool okay;
  U8 *st;
  F64 res;
  while (TRUE) {
    if (msg)
      "" msg,dft;
    st=GetStr;
    if (!*st) {
      Free(st);
      return dft;
    }
    try {
      res=ExePrint2("ToF64(%s);",st)(F64);
      okay=TRUE;
    } catch {
      Fs->catch_except=TRUE;
      okay=FALSE;
    }
    Free(st);
    if (okay && lo<=res<=hi)
      return res;
  }
}

Bool YorN()
{//Wait for user to answer Y or N.
  I64 ch;
  "(y or n)? ";
  while (TRUE) {
    ch=ToUpper(GetChar(,FALSE));
    if (ch=='Y') {
      "$$PT$$YES$$FG$$\n";
      return TRUE;
    } else if (ch=='N') {
      "$$PT$$NO$$FG$$\n";
      return FALSE;
    }
  }
}

Bool AreYouSure()
{
  "ARE YOU SURE ";
  return YorN;
}

//PopUps: the host shows a modal chooser (a mobile list dialog) and returns
//the chosen value, or DOCM_CANCEL. Mirrors Adam/DolDoc/DocPopUp.HC.
native I64 PopUpChoose(U8 *header,U8 *footer,U8 *labels,I64 *values,I64 *bgs,I64 cnt);

class CPopUpLst
{
  U8 *labels;
  I64 len,cap,cnt,values[256],bgs[256];
};

U0 PopUpLstAdd(CPopUpLst *l,U8 *label,I64 val,I64 bg=-1)
{
  I64 n=StrLen(label)+1;
  U8 *tmp;
  if (l->cnt>=256) return;
  if (l->len+n>l->cap) {
    tmp=MAlloc(l->cap*2+n);
    if (l->labels) {
      MemCpy(tmp,l->labels,l->len);
      Free(l->labels);
    }
    l->labels=tmp;
    l->cap=l->cap*2+n;
  }
  MemCpy(l->labels+l->len,label,n);
  l->len+=n;
  l->values[l->cnt]=val;
  l->bgs[l->cnt++]=bg;
}

I64 PopUpLstRun(CPopUpLst *l,U8 *header=NULL,U8 *footer=NULL)
{
  I64 res=PopUpChoose(header,footer,l->labels,l->values,l->bgs,l->cnt);
  Free(l->labels);
  Free(l);
  return res;
}

public I64 PopUpPickLst(U8 *lst)
{//Prompt for lst entry. Returns index or DOCM_CANCEL.
  I64 i=0;
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  while (*lst) {
    if (*lst=='@') {
      i--;
      lst++;
    }
    PopUpLstAdd(l,lst,i++);
    lst+=StrLen(lst)+1;
  }
  PopUpLstAdd(l,"CANCEL",DOCM_CANCEL);
  return PopUpLstRun(l);
}

public I64 PopUp1(U8 *b1,I64 n1,U8 *header=NULL,U8 *footer=NULL)
{
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  PopUpLstAdd(l,b1,n1);
  return PopUpLstRun(l,header,footer);
}

public I64 PopUp2(U8 *b1,I64 n1,U8 *b2,I64 n2,U8 *header=NULL,U8 *footer=NULL)
{
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  PopUpLstAdd(l,b1,n1);
  PopUpLstAdd(l,b2,n2);
  return PopUpLstRun(l,header,footer);
}

public Bool PopUpOk(U8 *header=NULL,U8 *footer=NULL)
{
  return PopUp1("OKAY",1,header,footer)>0;
}

public Bool PopUpNoYes(U8 *header=NULL,U8 *footer=NULL)
{
  return PopUp2("YES",1,"NO",0,header,footer)>0;
}

public Bool PopUpCancelOk(U8 *header=NULL,U8 *footer=NULL)
{
  return PopUp2("OKAY",1,"CANCEL",0,header,footer)>0;
}

public I64 PopUpRangeI64(I64 lo,I64 hi,I64 step=1,U8 *header=NULL,U8 *footer=NULL)
{//Evenly-spaced I64 range chooser.
  I64 i;
  U8 buf[STR_LEN];
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  for (i=lo;i<=hi;i+=step) {
    StrPrint(buf,"%d",i);
    PopUpLstAdd(l,buf,i);
  }
  return PopUpLstRun(l,header,footer);
}

public F64 PopUpRangeF64(F64 lo,F64 hi,F64 step,U8 *fmt="%9.4f",U8 *header=NULL,U8 *footer=NULL)
{//Evenly-spaced F64 range chooser.
  F64 d;
  U8 buf[STR_LEN];
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  for (d=lo;d<=hi;d+=step) {
    StrPrint(buf,fmt,d);
    PopUpLstAdd(l,buf,d(I64));
  }
  return PopUpLstRun(l,header,footer)(F64);
}

public F64 PopUpRangeF64Exp(F64 lo,F64 hi,F64 factor,U8 *fmt="%9.4f",U8 *header=NULL,U8 *footer=NULL)
{//Exp-spaced F64 range chooser.
  F64 d;
  U8 buf[STR_LEN];
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  for (d=lo;d<=hi;d*=factor) {
    StrPrint(buf,fmt,d);
    PopUpLstAdd(l,buf,d(I64));
  }
  return PopUpLstRun(l,header,footer)(F64);
}

public F64 PopUpRangeF64Log(F64 lo,F64 hi,I64 steps,U8 *fmt="%9.4f",U8 *header=NULL,U8 *footer=NULL)
{
  return PopUpRangeF64Exp(lo,hi,Exp(Ln(hi/lo)/(steps-1)),fmt,header,footer);
}

U8 *color_names[COLORS_NUM]={"BLACK","BLUE","GREEN","CYAN","RED","PURPLE","BROWN","LTGRAY",
  "DKGRAY","LTBLUE","LTGREEN","LTCYAN","LTRED","LTPURPLE","YELLOW","WHITE"};

public I64 PopUpColor(U8 *header=NULL,Bool allow_transparent=TRUE,Bool allow_dft=TRUE)
{//Chooser for 16-color, default or transparent.
  I64 i;
  CPopUpLst *l=CAlloc(sizeof(CPopUpLst));
  if (allow_transparent)
    PopUpLstAdd(l,"TRANSPARENT",TRANSPARENT);
  for (i=0;i<COLORS_NUM;i++)
    PopUpLstAdd(l,color_names[i],i,i);
  if (allow_dft)
    PopUpLstAdd(l,"DEFAULT",DOC_DFT);
  return PopUpLstRun(l,header);
}

public U8 *PopUpGetStr(U8 *header=NULL)
{//Prompt for text str.
  if (header) "%s",header;
  return GetStr;
}

native U8 *MobileDirLst(U8 *dir); //the files of a directory as a list

//Adam/DolDoc/DocPopUp.HC PopUpFileName shows a DolDoc form to edit the name and PopUpPickFile
//runs FileMgr; TempleOS Mobile has neither, so these offer the same choices as native lists:
//the default name (or cancel), and the directory's files.
public U8 *PopUpFileName(U8 *dft=NULL,I64 dof_flags=0)
{//Filename chooser: the default name or cancel.
  CPopUpLst *l;
  no_warn dof_flags;
  if (!dft) return NULL;
  l=CAlloc(sizeof(CPopUpLst));
  PopUpLstAdd(l,dft,0);
  PopUpLstAdd(l,"CANCEL",DOCM_CANCEL);
  if (PopUpLstRun(l,"Save as")) return NULL;
  return StrNew(dft);
}

public U8 *PopUpPickFile(U8 *dir=NULL)
{//Filename chooser: the files in dir (default: current dir).
  U8 *lst,*res=NULL,*d=dir;
  I64 i;
  if (!d) d=".";
  if (!(lst=MobileDirLst(d))) return NULL;
  if (*lst && (i=PopUpPickLst(lst))>=0)
    res=MStrPrint("%s/%s",d,LstSub(i,lst));
  Free(lst);
  return res;
}

public I64 PopUpGetI64(U8 *msg,I64 dft,I64 lo=I64_MIN,I64 hi=I64_MAX)
{
  return GetI64(msg,dft,lo,hi);
}

public F64 PopUpGetF64(U8 *msg,F64 dft,F64 lo=F64_MIN,F64 hi=F64_MAX)
{
  return GetF64(msg,dft,lo,hi);
}

//---------------------------------------------------------------- tasks & windows
native CTask *Spawn(U0 (*fp_start_addr)(U8 *data),U8 *data=NULL,U8 *task_name=NULL,I64 target_cpu=-1,CTask *parent=NULL,I64 stk_size=0,I64 flags=0);
native U0 Kill(CTask *task,Bool wait=TRUE,Bool just_break=FALSE);
native U0 Exit();
native Bool TaskValidate(CTask *task);
native U0 Suspend(CTask *task=NULL,Bool state=TRUE);
//Window geometry and task settings are the original TempleOS code (defined below,
//after GrLib.HC): programs get TempleOS's own window coordinates.
public U0 WinMax(CTask *task=NULL);
public Bool WinBorder(Bool val=OFF,CTask *task=NULL);
public Bool WinHorz(I64 left,I64 right,CTask *task=NULL);
public Bool WinVert(I64 top,I64 bottom,CTask *task=NULL);
native U0 WinToTop(CTask *task=NULL,Bool update_z_buf=TRUE);
native U0 WinFocus(CTask *task=NULL);
U0 TaskDerivedValsUpdate(CTask *task=NULL,Bool update_z_buf=TRUE);
public CTaskSettings *SettingsPush(CTask *task=NULL,I64 flags=0);
public U0 SettingsPop(CTask *task=NULL,I64 flags=0);
native Bool AutoComplete(Bool val=OFF);
native CJob *JobQue(I64 (*fp_addr)(U8 *data),U8 *data=NULL,I64 target_cpu=1,I64 flags=0,I64 cmd_code=0,U8 *aux_str=NULL,I64 aux1=0,I64 aux2=0);
native I64 JobResGet(CJob *tmpc=NULL);
native U0 Spaces(I64 n);
native I64 mp_cnt();
native CMenu *MenuNew(U8 *st,I64 flags=0,CTask *task=NULL);
native U0 MPInt(U8 num,I64 cpu_num=1);
U0 WinDerivedValsUpdate(CTask *task);
native I64 FramePtr(U8 *name,CTask *task=NULL);
native U0 FramePtrAdd(U8 *name,I64 val=0,CTask *task=NULL);
native I64 FramePtrSet(U8 *name,I64 val,CTask *task=NULL);
native I64 FramePtrDel(U8 *name,CTask *task=NULL);
native U0 SleepUntil(I64 wake_jiffy);

U0 Restart() {Kill(Fs);}

//---------------------------------------------------------------- sound
native U0 Snd(I8 ona=0);
native U0 SndFreq(F64 freq);
native Bool Mute(Bool val);
native Bool IsMute();
native U0 SndRst();
native F64 Ona2Freq(I8 ona);
native I8 Freq2Ona(F64 freq);

U0 Beep(I8 ona=62,Bool busy=FALSE)
{//Make beep at given pitch.
  no_warn busy;
  Snd(ona);
  Sleep(500);
  Snd;
  Sleep(200);
}

//---------------------------------------------------------------- files
native U8 *FileRead(U8 *filename,I64 *_size=NULL,I64 *_attr=NULL);
native I64 FileWrite(U8 *filename,U8 *fbuf,I64 size,CDate cdt=0,I64 attr=0);
native Bool FileFind(U8 *filename,I64 *_de=NULL,I64 fuf_flags=0);
native I64 Dir(U8 *files_find_mask="*",Bool full=FALSE);
native Bool Cd(U8 *dirname=NULL,Bool make_dirs=FALSE);
native U8 *DirCur(CTask *task=NULL,CTask *mem_task=NULL);
native Bool DirMk(U8 *filename,I64 entry_cnt=0);
native I64 Del(U8 *files_find_mask,Bool make_mask=FALSE,Bool del_dir=FALSE,Bool print_msg=TRUE);
native I64 DelTree(U8 *files_find_mask,U8 *fu_flags=NULL);
native Bool Copy(U8 *src_files_find_mask,U8 *dst_files_find_mask=".");
native Bool Move(U8 *f1,U8 *f2);
native U0 Type(U8 *filename,I64 trailing_new_lines=1);
native I64 ExeFile(U8 *name,I64 ccf_flags=0);
native Bool RegDft(U8 *path,U8 *val,Bool is_adam_entry=FALSE);
native I64 RegExe(U8 *path);
native Bool RegWrite(U8 *path,U8 *fmt,...);
native I64 RegCnt(U8 *path);
native U0 TaskRep();

Bool Blink(F64 Hz=2.5)
{//Return TRUE, then FALSE, then TRUE at given frequency.
  if (!Hz) return 0;
  return ToI64(cnts.jiffies*2*Hz/JIFFY_FREQ)&1;
}

public Bool MobileLegacyView()
{//Go live for user interaction until <ESC> or <SHIFT-ESC> (Adam/DolDoc/DocEd.HC).
  I64 ch;
  do ch=GetKey;
  while (ch!=CH_ESC && ch!=CH_SHIFT_ESC);
  return ch==CH_ESC;
}
native U0 Ed(U8 *filename);
native U0 Man(U8 *st);
native U0 Help();
native U8 *FileNameAbs(U8 *_filename,I64 fuf_flags=0);
native U0 DocLink(U8 *filename);

I64 TextFileWrite(U8 *filename,U8 *st)
{
  return FileWrite(filename,st,StrLen(st));
}

U8 *TextFileRead(U8 *filename,I64 *_attr=NULL)
{
  return FileRead(filename,NULL,_attr);
}

//---------------------------------------------------------------- graphics
//Device contexts and 4x4 fixed-point matrices. Adapted from TempleOS V5.03
//Adam/Gr/GrDC.HC and Adam/Gr/GrMath.HC (public domain, Terry A. Davis).

CBGR48 gr_palette_std[COLORS_NUM]={
0x000000000000,0x00000000AAAA,0x0000AAAA0000,0x0000AAAAAAAA,
0xAAAA00000000,0xAAAA0000AAAA,0xAAAA55550000,0xAAAAAAAAAAAA,
0x555555555555,0x55555555FFFF,0x5555FFFF5555,0x5555FFFFFFFF,
0xFFFF55555555,0xFFFF5555FFFF,0xFFFFFFFF5555,0xFFFFFFFFFFFF};

public I64 gr_x_offsets[8]={-1, 0, 1,-1,1,-1,0,1},
	   gr_y_offsets[8]={-1,-1,-1, 0,0, 1,1,1},
	  gr_x_offsets2[4]={ 0,-1, 1, 0},
	  gr_y_offsets2[4]={-1, 0, 0, 1};

//Mat4x4MulXYZ and DCTransform (GrDC.HC) run natively: they are called per vertex.
native U0 Mat4x4MulXYZ(I64 *r,I64 *_x,I64 *_y,I64 *_z);
native U0 DCTransform(CDC *dc,I64 *_x,I64 *_y,I64 *_z);

public I64 *Mat4x4IdentEqu(I64 *r)
{//Set matrix to identity.
  MemSet(r,0,sizeof(I64)*16);
  r[0*4+0].i32[1]=1;
  r[1*4+1].i32[1]=1;
  r[2*4+2].i32[1]=1;
  r[3*4+3].i32[1]=1;
  return r;
}

public I64 *Mat4x4IdentNew(CTask *mem_task=NULL)
{
  return Mat4x4IdentEqu(MAlloc(sizeof(I64)*16,mem_task));
}

public I64 Mat4x4NormSqr65536(I64 *r)
{//Norm Squared of r.
  return SqrI64((r[0*4+0]*37838+r[0*4+1]*37838+r[0*4+2]*37838)>>32)+
	SqrI64((r[1*4+0]*37837+r[1*4+1]*37837+r[1*4+2]*37837)>>32)+
	SqrI64((r[2*4+0]*37837+r[2*4+1]*37837+r[2*4+2]*37837)>>32);
}

public U0 DCMat4x4Set(CDC *dc=NULL,I64 *r)
{//Set device context's rot matrix. Will be Free()d in DCDel().
  if (!dc) dc=gr.dc;
  dc->r=r;
  dc->r_norm=Sqrt(Mat4x4NormSqr65536(r))*65536; //scaled 32 bits
}

//DCLighting runs natively (Raster.lighting): Gr3Mesh calls it for every triangle (ZoneOut, Titanium,
//Wenceslas, KeepAway). The original (Adam/Gr/GrDC.HC) is kept as DCLighting_HC for RasterDiffTest.
native public U0 DCLighting(CDC *dc,CD3I32 *p1,CD3I32 *p2,CD3I32 *p3,CColorROPU32 color);
public U0 DCLighting_HC(CDC *dc,
	CD3I32 *p1,CD3I32 *p2,CD3I32 *p3,CColorROPU32 color)
{//This is the dft dc->lighting() callback.
  CD3I32 v1,v2;
  I64 i,vn_x,vn_y,vn_z;
  F64 d;

  v1.x=p1->x-p2->x;
  v1.y=p1->y-p2->y;
  v1.z=p1->z-p2->z;

  v2.x=p3->x-p2->x;
  v2.y=p3->y-p2->y;
  v2.z=p3->z-p2->z;

  //V1 and V2 are vects along two sides
  //of the tri joined at p2.

  vn_x=v1.y*v2.z-v1.z*v2.y;
  vn_y=v1.z*v2.x-v1.x*v2.z;
  vn_z=v1.x*v2.y-v1.y*v2.x;
  if (d=Sqrt(SqrI64(vn_x)+SqrI64(vn_y)+SqrI64(vn_z)))
    d=1<<16/d;
  vn_x*=d;
  vn_y*=d;
  vn_z*=d;
//Vn is the cross product of V1 and V3
  //which means it is perpendicular.  It
  //is the normal vect to the surface.
  //It has been scaled to length 65536.

  //Light source has been scaled to length 65536.
  i=(vn_x*dc->ls.x+vn_y*dc->ls.y+vn_z*dc->ls.z)>>16;
//The dot product of the light source
  //vect and the surface normal
  //gives an illumination number.
  //65536*65536>>16=65536

  //TempleOS will generate a random U16
  //and compare to dither_probability_u16 and
  //will pick from two colors.
  //Probability dithering does not work with thick>1 at this time.
  if (color.c0.rop&ROPBF_TWO_SIDED) {
    color.c0.rop&=~ROPBF_TWO_SIDED;
    i=AbsI64(i)<<1;
  } else
    i+=65536;
  if (color.c0.rop&ROPBF_HALF_RANGE_COLOR) {
    color.c0.rop&=~ROPBF_HALF_RANGE_COLOR;
    i>>=1;
    if (color>=8) {
      color-=8;
      i+=65536;
    }
  }
  if (i<65536) {
    dc->color=ROPF_PROBABILITY_DITHER+color<<16+BLACK;
    dc->dither_probability_u16=i;
  } else {
    dc->color=ROPF_PROBABILITY_DITHER+(color^8)<<16+color;
    dc->dither_probability_u16=i-65536;
  }
}

public U0 DCFill(CDC *dc=NULL,CColorROPU32 val=TRANSPARENT)
{//Fill entire device context with color.
  if (!dc) dc=gr.dc;
  MemSet(dc->body,val,dc->width_internal*dc->height);
}

public U0 DCClear(CDC *dc=NULL)
{//Set entire device context image body to 0 (BLACK).
  if (!dc) dc=gr.dc;
  DCFill(dc,0);
}

public U0 DCRst(CDC *dc)
{//Reset CDC structure members but not image body, itself.
  dc->color=BLACK;
  dc->color2=BLACK;
  dc->bkcolor=BLACK;
  dc->collision_cnt=0;
  dc->thick=1;
  dc->ls.x=37837; //1<<16/Sqrt(3)
  dc->ls.y=37837;
  dc->ls.z=37837;
  dc->x=0;
  dc->y=0;
  dc->z=0;
  dc->transform=&DCTransform;
  dc->lighting =&DCLighting;
  Mat4x4IdentEqu(dc->r);
  dc->r_norm=GR_SCALE;
  dc->flags&=~(DCF_SYMMETRY|DCF_TRANSFORMATION|DCF_JUST_MIRROR);
  MemCpy(dc->palette,gr_palette_std,sizeof(CBGR48)*COLORS_NUM);
}

public U0 DCExtentsInit(CDC *dc=NULL)
{//Init markers for extent of next newly drawn graphics.
  if (!dc)   dc=gr.dc;
  dc->flags|=DCF_RECORD_EXTENTS;
  dc->min_x=I64_MAX;
  dc->max_x=I64_MIN;
  dc->min_y=I64_MAX;
  dc->max_y=I64_MIN;
}

native U0 GrUsed();

public CDC *DCAlias(CDC *dc=NULL,CTask *task=NULL)
{//Create alias of dc, so can change pen, color, etc.
  CDC *res;
  if (!dc)   dc=gr.dc;
  if (!task) task=Fs;
  if (dc->dc_signature!=DCS_SIGNATURE_VAL)
    throw('Graphics');
  GrUsed;
  res=MAlloc(sizeof(CDC),task);
  MemCpy(res,dc,sizeof(CDC));
  res->win_task=res->mem_task=task;
  res->r=MAlloc(16*sizeof(I64),task);
  DCRst(res);
  res->flags|=DCF_ALIAS;
  res->alias=dc;
  return res;
}

public CDC *DCNew(I64 width,I64 height,CTask *task=NULL,Bool null_bitmap=FALSE)
{//Create new width x height device context.
  CDC *res;
  if (!task) task=Fs;
  res=CAlloc(sizeof(CDC),task);
  res->win_task=task;
  res->mem_task=task;
  res->width=width;
  res->width_internal=(width+7)&~7;
  res->height=height;
  if (null_bitmap)
    res->flags|=DCF_DONT_DRAW;
  else
    res->body=CAlloc(res->width_internal*res->height,task);
  res->r=MAlloc(16*sizeof(I64),task);
  DCRst(res);
  res->dc_signature=DCS_SIGNATURE_VAL;
  return res;
}

public U0 DCDel(CDC *dc)
{//Free dc, image body, rot mat and depth buf.
  if (!dc) return;
  if (dc->dc_signature!=DCS_SIGNATURE_VAL)
    throw('Graphics');
  dc->dc_signature=0;
  Free(dc->r);
  if (!(dc->flags & DCF_ALIAS))
    Free(dc->body);
  Free(dc->depth_buf);
  Free(dc);
}

public I64 DCSize(CDC *dc)
{
  if (dc)
    return MSize2(dc)+MSize2(dc->body)+MSize2(dc->depth_buf);
  else
    return 0;
}

public I32 *DCDepthBufRst(CDC *dc)
{//Reset device context depth buf to far away.
  if (dc->depth_buf)
    MemSetU32(dc->depth_buf,I32_MAX,dc->width_internal*dc->height);
  return dc->depth_buf;
}

public I32 *DCDepthBufAlloc(CDC *dc)
{//Alloc a 32-bit depth buffer for device context.
  Free(dc->depth_buf);
  dc->depth_buf=MAlloc(dc->width_internal*dc->height*sizeof(I32),dc->mem_task);
  return DCDepthBufRst(dc);
}


public U0 DCMono(CDC *dc,I64 quest=TRANSPARENT,I64 true_color=0,I64 false_color=COLOR_MONO)
{//Set entire device context to mono based on whether pixel matches quest.
  I64 i;
  U8 *dst=dc->body;
  for (i=dc->width_internal*dc->height;i;i--)
    if (*dst==quest)
      *dst++=true_color;
    else
      *dst++=false_color;
}

public I64 DCColorChg(CDC *dc,I64 src_color,I64 dst_color=TRANSPARENT)
{//Find and replace src color with dst in device context.
  I64 i,res=0;
  U8 *dst=dc->body;
  for (i=dc->width_internal*dc->height;i;i--)
    if (*dst==src_color) {
      *dst++=dst_color;
      res++;
    } else
      dst++;
  return res;
}

//Mat4x4MulMat4x4Equ runs natively (Raster.mulMat4x4): Sprite3 calls it for every sprite drawn with
//DCF_TRANSFORMATION (BomberGolf: 74 per frame). The original (Adam/Gr/GrMath.HC) is kept as
//Mat4x4MulMat4x4Equ_HC for the differential test (RasterDiffTest): same F64 sums in the same order.
native public I64 *Mat4x4MulMat4x4Equ(I64 *dst,I64 *m1,I64 *m2);
public I64 *Mat4x4MulMat4x4Equ_HC(I64 *dst,I64 *m1,I64 *m2)
{//Multiply 4x4 matrices and store in dst.
  I64 i,j,k;
  F64 sum;
  for (i=0;i<4;i++) {
    for (j=0;j<4;j++) {
      sum=0;
      for (k=0;k<4;k++)
	sum+=ToF64(m1[k+4*j])*ToF64(m2[i+4*k]);
      dst[i+4*j]=sum/GR_SCALE;
    }
  }
  return dst;
}

public I64 *Mat4x4MulMat4x4New(I64 *m1,I64 *m2,CTask *mem_task=NULL)
{
  return Mat4x4MulMat4x4Equ(MAlloc(sizeof(I64)*16,mem_task),m1,m2);
}

public I64 *Mat4x4Equ(I64 *dst,I64 *src)
{
  MemCpy(dst,src,sizeof(I64)*16);
  return dst;
}

public I64 *Mat4x4New(I64 *src,CTask *mem_task=NULL)
{
  return Mat4x4Equ(MAlloc(sizeof(I64)*16,mem_task),src);
}

public CDC *DCCopy(CDC *dc,CTask *task=NULL)
{//Alloc copy of dc, including image body, rot mat and depth buf.
  CDC *res;
  if (!dc) return NULL;
  if (dc->dc_signature!=DCS_SIGNATURE_VAL)
    throw('Graphics');
  res=MAllocIdent(dc,task);
  DCMat4x4Set(res,Mat4x4New(dc->r,task));
  res->mem_task=task;
  res->body=MAllocIdent(dc->body,task);
  res->depth_buf=MAllocIdent(dc->depth_buf,task);
  return res;
}

public I64 *Mat4x4RotX(I64 *m,F64 phi)
{//Rot matrix about X axis.
  F64 my_cos=Cos(phi)*GR_SCALE,my_sin=Sin(phi)*GR_SCALE;
  I64 r[16],r2[16];
  MemSet(r,0,sizeof(r));
  r[5]=my_cos;
  r[10]=my_cos;
  r[9]=my_sin;
  r[6]=-my_sin;
  r[0]=GR_SCALE;
  r[15]=GR_SCALE;
  return Mat4x4Equ(m,Mat4x4MulMat4x4Equ(r2,r,m));
}

public I64 *Mat4x4RotY(I64 *m,F64 omega)
{//Rot matrix about Y axis.
  F64 my_cos=Cos(omega)*GR_SCALE,my_sin=Sin(omega)*GR_SCALE;
  I64 r[16],r2[16];
  MemSet(r,0,sizeof(r));
  r[0]=my_cos;
  r[10]=my_cos;
  r[8]=-my_sin;
  r[2]=my_sin;
  r[5]=GR_SCALE;
  r[15]=GR_SCALE;
  return Mat4x4Equ(m,Mat4x4MulMat4x4Equ(r2,r,m));
}

public I64 *Mat4x4RotZ(I64 *m,F64 theta)
{//Rot matrix about Z axis.
  F64 my_cos=Cos(theta)*GR_SCALE,my_sin=Sin(theta)*GR_SCALE;
  I64 r[16],r2[16];
  MemSet(r,0,sizeof(r));
  r[0]=my_cos;
  r[5]=my_cos;
  r[4]=my_sin;
  r[1]=-my_sin;
  r[10]=GR_SCALE;
  r[15]=GR_SCALE;
  return Mat4x4Equ(m,Mat4x4MulMat4x4Equ(r2,r,m));
}

public I64 *Mat4x4Scale(I64 *m,F64 s)
{//Scale 4x4 matrix by value.
  I64 i;
  for (i=0;i<16;i++)
    m[i]*=s;
  return m;
}

public U0 DCThickScale(CDC *dc=NULL)
{//Scale device context's thick by norm of transformation.
  I64 d;
  if (!dc) dc=gr.dc;
  if (dc->flags&DCF_TRANSFORMATION) {
    if (dc->thick) {
      d=dc->thick*dc->r_norm+0x80000000; //Round
      dc->thick=d.i32[1];
      if (dc->thick<1)
	dc->thick=1;
    }
  }
}

public I64 *Mat4x4TranslationEqu(I64 *r,I64 x,I64 y,I64 z)
{//Set translation values in 4x4 matrix.
  r[0*4+3]=x<<32;
  r[1*4+3]=y<<32;
  r[2*4+3]=z<<32;
  r[3*4+3]=GR_SCALE;
  return r;
}

public I64 *Mat4x4TranslationAdd(I64 *r,I64 x,I64 y,I64 z)
{//Add translation to 4x4 matrix.
  r[0*4+3]+=x<<32;
  r[1*4+3]+=y<<32;
  r[2*4+3]+=z<<32;
  r[3*4+3]=GR_SCALE;
  return r;
}

public I64 *Mat4x4Transpose(I64 *r,CTask *mem_task=NULL)
{//Transpose a 4x4 matrix. MAllocs result.
  I64 i,j,*res=MAlloc(sizeof(I64)*16,mem_task);
  for (i=0;i<4;i++)
    for (j=0;j<4;j++)
      res[i+4*j]=r[j+4*i];
  return res;
}

public Bool Mat4x4IsIdent(I64 *r)
{
  I64 i;
  for (i=0;i<16;i++)
    if (i%5) {
      if (r[i]) return FALSE;
    } else if (r[i]!=GR_SCALE)
      return FALSE;
  return TRUE;
}

public Bool DCSymmetrySet(CDC *dc=NULL,I64 x1,I64 y1,I64 x2,I64 y2)
{//2D. Set device context's symmetry.
  F64 d;
  if (!dc) dc=gr.dc;
  if (y1==y2 && x1==x2)
    return FALSE;
  dc->sym.snx=y2-y1;
  dc->sym.sny=x1-x2;
  dc->sym.snz=0;
  if (d=Sqrt(SqrI64(dc->sym.snx)+
	SqrI64(dc->sym.sny)+
	SqrI64(dc->sym.snz))) {
    d=GR_SCALE/d;
    dc->sym.snx *= d;
    dc->sym.sny *= d;
    dc->sym.snz *= d;
  }
  dc->sym.sx=x1;
  dc->sym.sy=y1;
  dc->sym.sz=0;
  return TRUE;
}

public Bool DCSymmetry3Set(CDC *dc=NULL,I64 x1,I64 y1,I64 z1,
	I64 x2,I64 y2,I64 z2,I64 x3,I64 y3,I64 z3)
{//3D. Set device context's symmetry.
  F64 d,x,y,z,xx,yy,zz;
  I64 xx1,yy1,zz1,xx2,yy2,zz2,*r;
  if (!dc) dc=gr.dc;
  xx1=x1-x2; yy1=y1-y2; zz1=z1-z2;
  xx2=x3-x2; yy2=y3-y2; zz2=z3-z2;
  if (!xx1 && !yy1 && !zz1 ||
	!xx2 && !yy2 && !zz2 ||
	xx1==xx2 && yy1==yy2 && zz1==zz2)
    return FALSE;
  x=yy1*zz2-zz1*yy2;
  y=-xx1*zz2+zz1*xx2;
  z=xx1*yy2-yy1*xx2;
  if (dc->flags & DCF_TRANSFORMATION) {
    r=dc->r;
    xx=x*r[0]+y*r[1]+z*r[2];
    yy=x*r[4]+y*r[5]+z*r[6];
    zz=x*r[8]+y*r[9]+z*r[10];
    x=xx; y=yy; z=zz;
  }
  if (d=Sqrt(Sqr(x)+Sqr(y)+Sqr(z))) {
    d=GR_SCALE/d;
    dc->sym.snx = d*x;
    dc->sym.sny = d*y;
    dc->sym.snz = d*z;
  }
  if (dc->flags & DCF_TRANSFORMATION)
    (*dc->transform)(dc,&x1,&y1,&z1);
  dc->sym.sx=x1;
  dc->sym.sy=y1;
  dc->sym.sz=z1;
  return TRUE;
}

//Lowest-level primitives are native; the rest of the TempleOS graphics
//library (GrLib.HC) is the original HolyC compiled on top of them.
native Bool GrPlot0(CDC *dc,I64 x,I64 y);
native I64 GrPeek0(CDC *dc,I64 x,I64 y);
native Bool IsPixCovered0(CTask *task,I64 x,I64 y);
native I64 GrFloodFillRay(CDC *dc,I64 x,I64 y,I64 z,I32 *db);
native U8 *DefinePrint(U8 *dname,U8 *src,...);
native Bool Silent(Bool val=ON);
native Bool IsSilent();
native U8 *DefineLoad(U8 *dname,U8 *st);
native U8 *DefineLstLoad(U8 *dname,U8 *lst);
native U8 *Define(U8 *dname);
native U8 *DefineSub(I64 sub,U8 *dname);
native I64 DefineCnt(U8 *dname);
native U0 GrPaletteColorSet(I64 color_num,CBGR48 bgr48);
native CBGR48 GrPaletteColorGet(I64 color_num);
//Text layer blitters (x86 assembly in TempleOS GrTextBase.HC).
native Bool TextChar(CTask *task,Bool allow_border=FALSE,I64 x,I64 y,I64 d);
native Bool TextLenStr(CTask *task,I64 x,I64 y,I64 len,I64 attr,U8 *s);
native Bool TextLenAttrStr(CTask *task,I64 x,I64 y,I64 len,U32 *_attr);
native Bool TextLenAttr(CTask *task,I64 x,I64 y,I64 len,I64 attr);
native U0 Option(I64 num,I64 val);

U0 GrSetUpPens()
{//Pen brush and bit tables. Adapted from TempleOS Adam/Gr/GrInitB.HC GrSetUpTables().
  CDC *dc;
  I64 i,j,k,x,y,rr;
  gr.to_8_bits	=MAlloc(256*sizeof(I64));
  gr.to_8_colors=MAlloc(256*sizeof(I64));
  gr.scrn_zoom=1;
  k=0;
  for (i=0;i<256;i++)
    for (j=0;j<8;j++)
      if (Bt(&i,j))
	gr.to_8_bits(U8 *)[k++]=0xFF;
      else
	gr.to_8_bits(U8 *)[k++]=0x00;
  k=0;
  for (i=0;i<256;i++)
    for (j=0;j<8;j++)
      gr.to_8_colors(U8 *)[k++]=i;
  for (i=0;i<GR_PEN_BRUSHES_NUM;i++) {
    k=i+1;
    rr=k*k;
    for (y=1;y<k;y++)
      for (x=1;x<k;x++)
	if (SqrI64(y*2-k)+SqrI64(x*2-k)<rr) {
	  if (x-1-i>>1<gr.circle_lo[i][i-y])
	    gr.circle_lo[i][i-y]=x-1-i>>1;
	  if (x-1-i>>1>gr.circle_hi[i][i-y])
	    gr.circle_hi[i][i-y]=x-1-i>>1;
	}
    dc=DCNew(i,i);
    gr.pen_brushes[i]=dc;
    dc->color=COLOR_MONO;
    for (y=1;y<k;y++)
      for (x=1;x<k;x++)
	if (SqrI64(y*2-k)+SqrI64(x*2-k)<rr)
	  GrPlot0(dc,x-1,y-1);
    dc=DCNew(i,i);
    gr.collision_pen_brushes[i]=dc;
    dc->color=COLOR_INVALID;
    for (y=1;y<k;y++)
      for (x=1;x<k;x++)
	if (SqrI64(y*2-k)+SqrI64(x*2-k)<rr)
	  GrPlot0(dc,x-1,y-1);
    dc=DCNew(i,i);
    gr.even_pen_brushes[i]=dc;
    dc->color=COLOR_MONO;
    for (y=1;y<k;y++)
      for (x=1;x<k;x++)
	if (!(((x-1)^(y-1))&1) && SqrI64(y*2-k)+SqrI64(x*2-k)<rr)
	  GrPlot0(dc,x-1,y-1);
    dc=DCNew(i,i);
    gr.odd_pen_brushes[i]=dc;
    dc->color=COLOR_MONO;
    for (y=1;y<k;y++)
      for (x=1;x<k;x++)
	if (((x-1)^(y-1))&1 && SqrI64(y*2-k)+SqrI64(x*2-k)<rr)
	  GrPlot0(dc,x-1,y-1);
  }
}

#include "GrLib.HC"
native U8 *SysFont();

//---------------------------------------------------------------- windows
//TempleOS V5.03 window geometry: Kernel/Display.HC WinDerivedValsUpdate,
//Kernel/KTask.HC TaskDerivedValsUpdate, Adam/Win.HC WinHorz/WinVert/WinMax/WinBorder.
//The host composes each window where TempleOS would (Kernel compose) and shows the
//window, so pix_left/pix_top/pix_width/pix_height mean what they mean in TempleOS.
#define DISPLAYf_SHOW			0
#define DISPLAYf_NOT_RAW		1
#define DISPLAYf_SILENT			2
#define DISPLAYf_NO_BORDER		3
#define DISPLAYf_WIN_ON_TOP		4
#define DISPLAYf_CHILDREN_NOT_ON_TOP	5
#define TSF_SAME_SONG	1

U0 WinDerivedValsUpdate(CTask *task)
{//Those things calculated from other variables.
  if (!task) task=Fs;
  task->win_width =task->win_right-task->win_left+1;
  task->win_height=task->win_bottom-task->win_top+1;
  task->pix_left	=FONT_WIDTH*task->win_left;
  task->pix_right	=FONT_WIDTH*(task->win_right+1)-1;
  task->pix_width	=task->pix_right-task->pix_left+1;
  task->pix_top		=FONT_HEIGHT*task->win_top;
  task->pix_bottom	=FONT_HEIGHT*(task->win_bottom+1)-1;
  task->pix_height	=task->pix_bottom-task->pix_top+1;
}

U0 TaskDerivedValsUpdate(CTask *task=NULL,Bool update_z_buf=TRUE)
{//Those things calculated from other variables.
  no_warn update_z_buf; //single window: no z-buffer to update
  if (!task) task=Fs;
  WinDerivedValsUpdate(task);
  if (fp_update_ctrls)
    (*fp_update_ctrls)(task);
}

public Bool WinHorz(I64 left,I64 right,CTask *task=NULL)
{//Set task's win left and right columns.
  I64 d=right-left;
  if (!task) task=Fs;
  if (!TaskValidate(task)) return FALSE;
  if (d<0) d=0;
  if (left>=TEXT_COLS) {
    left=TEXT_COLS-1;
    right=left+d;
  }
  if (right<0) {
    right=0;
    left=right-d;
  }
  if (left>right) {
    if (left>0)
      right=left;
    else
      left=right;
  }
  if (task->win_left!=left || task->win_right!=right) {
    task->win_left=left;
    task->win_right=right;
    TaskDerivedValsUpdate(task);
    return TRUE;
  } else
    return FALSE;
}

public Bool WinVert(I64 top,I64 bottom,CTask *task=NULL)
{//Set task's win top and bottom rows.
  I64 d=bottom-top;
  if (!task) task=Fs;
  if (!TaskValidate(task)) return FALSE;
  if (d<0) d=0;
  if (top>=TEXT_ROWS) {
    top=TEXT_ROWS-1;
    bottom=top+d;
  }
  if (bottom<=0) {
    bottom=1;
    top=bottom-d;
  }
  if (top>bottom) {
    if (top>=0)
      bottom=top;
    else
      top=bottom;
  }
  if (task->win_top!=top || task->win_bottom!=bottom) {
    task->win_top=top;
    task->win_bottom=bottom;
    TaskDerivedValsUpdate(task);
    return TRUE;
  } else
    return FALSE;
}

public U0 WinMax(CTask *task=NULL)
{//Maximize task's window
  I64 no_border;
  if (!task) task=Fs;
  if (!TaskValidate(task)) return;
  no_border=Bt(&task->display_flags,DISPLAYf_NO_BORDER);
  WinHorz(1-no_border,TEXT_COLS-2+no_border,task);
  WinVert(2-no_border,TEXT_ROWS-2+no_border,task);
  WinToTop(task);
}

public Bool WinBorder(Bool val=OFF,CTask *task=NULL)
{//Turn off (or on) window border.
  Bool old_has_border;
  if (!task) task=Fs;
  if (!TaskValidate(task)) return FALSE;
  old_has_border=!Bt(&task->display_flags,DISPLAYf_NO_BORDER);
  if (val) {
    if (!old_has_border) {
      LBtr(&task->display_flags,DISPLAYf_NO_BORDER);
      task->win_left++; task->win_right--;
      task->win_top++;	task->win_bottom--;
      TaskDerivedValsUpdate(task,FALSE);
    }
  } else {
    if (old_has_border) {
      LBts(&task->display_flags,DISPLAYf_NO_BORDER);
      task->win_left--; task->win_right++;
      task->win_top--;	task->win_bottom++;
      TaskDerivedValsUpdate(task,FALSE);
    }
  }
  return old_has_border;
}

//---------------------------------------------------------------- task settings
//TempleOS V5.03 Adam/TaskSettings.HC. Omitted: the DolDoc cursor/scroll-bar flags
//(no CDoc here) and AutoComplete (not modelled).
public U0 GrPaletteGet(CBGR48 *bgr48)
{//16 colors (Adam/Gr/GrPalette.HC)
  I64 i;
  for (i=0;i<COLORS_NUM;i++)
    bgr48[i]=GrPaletteColorGet(i);
}

public U0 GrPaletteSet(CBGR48 *bgr48)
{//16 colors (Adam/Gr/GrPalette.HC)
  I64 i;
  for (i=0;i<COLORS_NUM;i++)
    GrPaletteColorSet(i,bgr48[i]);
}

public CTaskSettings *SettingsPush(CTask *task=NULL,I64 flags=0)
{//Typically, called at start of an application.
//It saves many settings so they can be restored
  //at the end of the application with SettingsPop().
  CTaskSettings *tmpse;
  if (!task) task=Fs;
  if (!TaskValidate(task)) return NULL;
  tmpse=CAlloc(sizeof(CTaskSettings),task);
  tmpse->cur_dir=DirCur(task,task);
  tmpse->draw_it=task->draw_it;
  GrPaletteGet(tmpse->palette);
  tmpse->task_end_cb=task->task_end_cb;

  if (!(flags&TSF_SAME_SONG)) {
    if (tmpse->song_task=task->song_task) {
      Suspend(task->song_task);
      Snd;
    }
    task->song_task=NULL;
  }

  if (tmpse->animate_task=task->animate_task)
    Suspend(task->animate_task);
  task->animate_task=NULL;

  tmpse->left=task->win_left;
  tmpse->right=task->win_right;
  tmpse->top=task->win_top;
  tmpse->bottom=task->win_bottom;

  tmpse->scroll_x=task->scroll_x;
  tmpse->scroll_y=task->scroll_y;
  tmpse->scroll_z=task->scroll_z;

  tmpse->win_inhibit=task->win_inhibit;
  tmpse->text_attr=task->text_attr;
  StrCpy(tmpse->task_title,task->task_title);
  tmpse->title_src  =task->title_src;
  tmpse->border_attr=task->border_attr;
  tmpse->border_src =task->border_src;
  tmpse->border=!Bt(&task->display_flags,DISPLAYf_NO_BORDER);

  tmpse->next=task->next_settings;
  task->next_settings=tmpse;
  return tmpse;
}

U0 SettingsPop2(CTask *task,CTaskSettings *tmpse)
{
  WinBorder(tmpse->border,task);
  WinHorz(tmpse->left,tmpse->right,task);
  WinVert(tmpse->top,tmpse->bottom,task);
  task->scroll_x=tmpse->scroll_x;
  task->scroll_y=tmpse->scroll_y;
  task->scroll_z=tmpse->scroll_z;
  task->win_inhibit=tmpse->win_inhibit;
  task->text_attr=tmpse->text_attr;
  task->border_attr=tmpse->border_attr;
  task->border_src =tmpse->border_src;
  task->title_src  =tmpse->title_src;
  StrCpy(task->task_title,tmpse->task_title);
  GrPaletteSet(tmpse->palette);
  Snd;
}

public U0 SettingsPop(CTask *task=NULL,I64 flags=0)
{//Typically, called at end of an application.
  CTaskSettings *tmpse;
  if (!task) task=Fs;
  if (!TaskValidate(task))
    return;
  if (tmpse=task->next_settings) {
    task->next_settings=tmpse->next;
    Cd(tmpse->cur_dir);
    Free(tmpse->cur_dir);
    task->draw_it=tmpse->draw_it;
    task->task_end_cb=tmpse->task_end_cb;

    if (task->animate_task)
      Kill(task->animate_task);
    if (task->animate_task=tmpse->animate_task)
      Suspend(task->animate_task,FALSE);

    if (!(flags&TSF_SAME_SONG)) {
      if (task->song_task)
	Kill(task->song_task);
      if (task->song_task=tmpse->song_task)
	Suspend(task->song_task,FALSE);
    }

    SettingsPop2(task,tmpse); //Do it to get ress fast
    Refresh(,TRUE);
    SettingsPop2(task,tmpse); //Redo in case was lost by old update

    Free(tmpse);
  }
}

//---------------------------------------------------------------- window manager glue
//Per-frame window manager duties for one task, after Adam/WinMgr.HC and
//Adam/Gr/GrScrn.HC: ODE integration, controls, and mouse routing to controls.
CCtrl *mobile_ctrl_capture_l,*mobile_ctrl_capture_r;
Bool mobile_old_lb,mobile_old_rb;
I64 mobile_ms_z=0;

U0 MobileCtrlCoords(CTask *task,CCtrl *c,I64 *_left,I64 *_top)
{
  *_left=task->pix_left;
  *_top =task->pix_top;
  if (c->flags&CTRLF_BORDER) {
    *_left-=FONT_WIDTH;
    *_top -=FONT_HEIGHT;
  }
}

U0 MobileCtrlsMs(CTask *task)
{
  CCtrl *c;
  I64 left,top;
  Bool hit=FALSE;
  if (Bt(&task->win_inhibit,WIf_SELF_CTRLS)) return;
  if (c=mobile_ctrl_capture_l) {
    MobileCtrlCoords(task,c,&left,&top);
    if (c->left_click)
      (*c->left_click)(c,ms.pos.x-left,ms.pos.y-top,ms.lb);
    if (!ms.lb) {
      mobile_ctrl_capture_l=NULL;
      mobile_old_lb=FALSE;
    }
    return;
  }
  if (c=mobile_ctrl_capture_r) {
    MobileCtrlCoords(task,c,&left,&top);
    if (c->right_click)
      (*c->right_click)(c,ms.pos.x-left,ms.pos.y-top,ms.rb);
    if (!ms.rb) {
      mobile_ctrl_capture_r=NULL;
      mobile_old_rb=FALSE;
    }
    return;
  }
  if (ms.lb!=mobile_old_lb || ms.rb!=mobile_old_rb) {
    c=task->next_ctrl;
    while (c!=&task->next_ctrl) {
      if (CtrlInside(c,ms.pos.x,ms.pos.y)) {
	MobileCtrlCoords(task,c,&left,&top);
	if (ms.lb!=mobile_old_lb) {
	  if (ms.lb && c->flags&CTRLF_CAPTURE_LEFT_MS)
	    mobile_ctrl_capture_l=c;
	  if (c->left_click)
	    (*c->left_click)(c,ms.pos.x-left,ms.pos.y-top,ms.lb);
	}
	if (ms.rb!=mobile_old_rb) {
	  if (ms.rb && c->flags&CTRLF_CAPTURE_RIGHT_MS)
	    mobile_ctrl_capture_r=c;
	  if (c->right_click)
	    (*c->right_click)(c,ms.pos.x-left,ms.pos.y-top,ms.rb);
	}
	hit=TRUE;
	break;
      }
      c=c->next;
    }
  }
  if (!hit && ms.has_wheel && mobile_ms_z!=ms.pos.z) {
//The first control with a wheel handler takes the wheel (the window's vertical scroll bar).
    c=task->next_ctrl;
    while (c!=&task->next_ctrl) {
      if (c->wheel_chg) {
	(*c->wheel_chg)(c,ms.pos.z-mobile_ms_z);
	break;
      }
      c=c->next;
    }
    mobile_ms_z=ms.pos.z;
  }
  mobile_old_lb=ms.lb;
  mobile_old_rb=ms.rb;
}

U0 MobileOdeFrameEnd()
{//End of Adam/Gr/GrScrn.HC GrUpdateTasks: this frame's ODE time budgets the next frame.
  winmgr.last_ode_time=winmgr.ode_time;
  ode_alloced_factor=LowPass1(0.1,ode_alloced_factor,
	Clamp(Gs->idle_factor-0.1,0.2,0.8),1/winmgr.fps);
}

Bool MobileTaskHasCtrls(CTask *task)
{
  return task->next_ctrl!=&task->next_ctrl;
}

Bool MobileTaskHasOwnCtrls(CTask *task)
{//Controls besides the terminal window's scroll bars (Adam/DolDoc/DocTerm.HC WinScrollsInit).
  CCtrl *c=task->next_ctrl;
  while (c!=&task->next_ctrl) {
    if (c->type!=CTRLT_WIN_HSCROLL && c->type!=CTRLT_WIN_VSCROLL)
      return TRUE;
    c=c->next;
  }
  return FALSE;
}

Bool MobileMsInCtrl(CTask *task)
{//Adam/WinMgr.HC: no mouse messages are queued while the pointer is on a control.
  CCtrl *c=task->next_ctrl;
  while (c!=&task->next_ctrl) {
    if (CtrlInside(c,ms.pos.x,ms.pos.y))
      return TRUE;
    c=c->next;
  }
  return FALSE;
}

U0 MobileTaskInit(CTask *task)
{//Queue heads, as TempleOS TaskInit() does.
  QueInit(&task->next_ctrl);
  QueInit(&task->next_ode);
  task->next_settings=NULL;
  task->horz_scroll.max=0;
  task->vert_scroll.max=0;
}

//---- Compatibility additions: TempleOS globals and helpers that bundled
//---- programs use but that live outside the files GrLib.HC is built from.

//Kernel/KernelB.HH progress bars (shown on the TempleOS wallpaper; here plain globals).
public I64 progress1,progress1_max,progress2,progress2_max,
	progress3,progress3_max,progress4,progress4_max;
public F64 progress1_t0,progress1_tf,progress2_t0,progress2_tf,
	progress3_t0,progress3_tf,progress4_t0,progress4_tf;
public U8 progress1_desc[PROGRESS_DESC_LEN],progress2_desc[PROGRESS_DESC_LEN],
	progress3_desc[PROGRESS_DESC_LEN],progress4_desc[PROGRESS_DESC_LEN];

//Adam/Gr/GrPalette.HC
public U8 gr_rainbow_10[10]={
  BLACK,BROWN,RED,LTRED,YELLOW,GREEN,BLUE,PURPLE,LTGRAY,WHITE};

//Adam/ARegistry.HC
I64 sys_msg_flags[1]={0};

public Bool OneTimePopUp(U8 *_flags,I64 flag_num,U8 *msg)
{//Adaptation: a two-button choice instead of a DolDoc check box.
  Bool res=FALSE;
  if (!Bt(_flags,flag_num)) {
    if (PopUp2("OKAY",1,"OKAY, don't show again",2,msg)==2) {
      LBts(_flags,flag_num);
      res=TRUE;
    }
  }
  return res;
}

U0 RegOneTimePopUp(I64 flag_num,U8 *msg)
{
  OneTimePopUp(sys_msg_flags,flag_num,msg);
}

public U0 MemBIOSRep()
{//There is no PC BIOS: report that instead of a memory map.
  "BIOS memory map: not available in %s.\n",sys_mobile_platform;
}

//PC port I/O: there is no PC hardware. Reads return 0, writes are ignored.
public U8 InU8(I64 port) {return 0;}
public U16 InU16(I64 port) {return 0;}
public U32 InU32(I64 port) {return 0;}
native U0 MobileVgaPort(I64 port,I64 val);
native U0 MobileVgaSync();
public U0 OutU8(I64 port,I64 val) {MobileVgaPort(port,val);}
public U0 OutU16(I64 port,I64 val) {}
public U0 OutU32(I64 port,I64 val) {}

//Kernel/KDefine.HC
I64 DefineMatch(U8 *needle,U8 *haystack_lst_dname,I64 flags=0)
{//Find match for string in define list.
  return LstMatch(needle,Define(haystack_lst_dname),flags);
}

//The standard lists TempleOS loads at boot (Kernel/KDefine.HC SysDefinesLoad,
//Adam/Gr/GrPalette.HC); hardware/interrupt name lists are omitted.
DefineLstLoad("ST_OFF_ON","Off\0On\0");
DefineLstLoad("ST_DAYS_OF_WEEK","Sunday\0Monday\0Tuesday\0Wednesday\0"
	"Thursday\0Friday\0Saturday\0");
DefineLstLoad("ST_MONTHS","January\0February\0March\0April\0May\0"
	"June\0July\0August\0September\0October\0November\0December\0");
DefineLstLoad("ST_FILE_ATTRS","R\0H\0S\0V\0D\0A\0\0\0X\0T\0Z\0C\0F\0");
DefineLstLoad("ST_COLORS","BLACK\0BLUE\0GREEN\0CYAN\0"
	"RED\0PURPLE\0BROWN\0LTGRAY\0DKGRAY\0LTBLUE\0LTGREEN\0"
	"LTCYAN\0LTRED\0LTPURPLE\0YELLOW\0WHITE\0");
DefineLstLoad("ST_RAINBOW_10",
  "BLACK\0BROWN\0RED\0LTRED\0YELLOW\0GREEN\0BLUE\0PURPLE\0LTGRAY\0WHITE\0");

//Kernel/KMisc.HC (the wallpaper's registry hook is not modelled)
public U0 ProgressBarsRst(U8 *path=NULL)
{//Reset all progress bars to zero.
  progress1=progress1_max=progress2=progress2_max=0;
  progress3=progress3_max=progress4=progress4_max=0;
  *progress1_desc=*progress2_desc=*progress3_desc=*progress4_desc=0;
}

//Adam/Gr/GrGlbls.HC VGAFlush forces a full repaint of the VGA screen; frames
//here are always composed in full, so there is nothing to do.
public U0 VGAFlush() {MobileVgaSync;}

// Read-only DolDoc sprite output; original vector operations are rendered by Sprite2DC.
// Editable CDocEntry handles and document macros are not provided by this adapter.
native CDocEntry *Sprite(U8 *elems,U8 *fmt=NULL);

#include "DocLib.HC"

#include "TaskLib.HC"
#include "GraphicsCompat.HC"
