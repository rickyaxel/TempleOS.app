// Sandboxed equivalents of the V5.03 command server and file utilities.
// Jobs call original/translated functions through their real function pointers.
native U8 *MobileSymbol(U8 *name);
I64 Call(U8 *fp) {I64 (*function)()=fp;return (*function)();}
native U0 MobileJobRegister(CTask *owner,U8 *head);
native U8 *MobileSourceOpen(U8 *filename);
native U8 *MobileSourceNext(U8 *handle);
native U0 MobileSourceClose(U8 *handle);
native U0 MobileJobWait();
native U0 MobileJobWake(CTask *task);
native I64 MobileTaskState(CTask *task);
native CCmpCtrl *CmpCtrlNew(U8 *source,I64 flags=0,U8 *filename=NULL);
native U0 CmpCtrlDel(CCmpCtrl *cc);
native I64 Lex(CCmpCtrl *cc);
native U8 *LexExtStr(CCmpCtrl *cc);
native CDirEntry *FilesFind(U8 *mask,I64 flags=0);
native U0 DirTreeDel(CDirEntry *entries);
native I64 FileOcc(U8 *needle,U8 *filename,U8 *flags=NULL);
native U8 *MobileTaskCaller(CTask *task,I64 num=0);

native U8 *MobileScoreOpen(U8 *filename);
native U0 MobileScoreClose();
U0 MobileScorePlay(U8 *score)
{
  I64 i,n=score(I64 *)[2];U8 **events=score+24;
  Fs->task_end_cb=&SndTaskEndCB;MusicSettingsRst;
  music.tempo=score(F64 *)[0];music.stacatto_factor=score(F64 *)[1];
  try {while(!ScanKey) for(i=0;i<n;i++) Play(events[2*i],events[2*i+1]);}
  catch PutExcept;
  Snd;
}

class MobileJob
{
  MobileJob *next,*last;
  I64 flags,argc;
  U8 *fp;
  I64 args[8];
  U8 *strings[8];
};

MobileJob *MobileJobHead(CTask *task)
{
  U8 *name=MStrPrint("MobileJobs:%X",task);
  MobileJob *head=FramePtr(name,task);
  if(!head) {head=CAlloc(sizeof(MobileJob));QueInit(head);FramePtrAdd(name,head,task);MobileJobRegister(task,head);}
  Free(name);return head;
}

U0 SrvCmdLine(I64 dummy=0)
{
  MobileJob *head=MobileJobHead(Fs),*job;
  I64 i,flags;U8 *source,*score;
  I64 (*fp)(I64,I64,I64,I64,I64,I64,I64,I64);
  no_warn dummy;
  while(TRUE) {
    while(head->next==head) MobileJobWait;
    job=head->next;QueRem(job);head->flags=1;head->fp=job;flags=job->flags;
    fp=job->fp;
    if(job->fp==MobileSymbol("ExeFile")) {
      score=MobileScoreOpen(job->args[0]);
      if(score) {MobileScorePlay(score);MobileScoreClose;}
      else {
        source=MobileSourceOpen(job->args[0]);
        while(fp=MobileSourceNext(source)) (*fp)(0,0,0,0,0,0,0,0);
        MobileSourceClose(source);
      }
    } else if(fp) (*fp)(job->args[0],job->args[1],job->args[2],job->args[3],job->args[4],job->args[5],job->args[6],job->args[7]);
    head->flags=0;head->fp=NULL;
    for(i=0;i<8;i++) Free(job->strings[i]);
    Free(job);
    if(flags&(1<<JOBf_EXIT_ON_COMPLETE)) return;
  }
}

U8 *TaskExe(CTask *task,CTask *master,U8 *source,I64 flags)
{
  MobileJob *head=MobileJobHead(task),*job=NULL,*last=NULL;
  CCmpCtrl *cc=CmpCtrlNew(source);
  I64 token,i,sign;
  U8 *name;
  no_warn master;
  token=Lex(cc);
  while(token) {
    if(token==';') {token=Lex(cc);continue;}
    if(token!=TK_IDENT) {CmpCtrlDel(cc);throw('Compiler');}
    name=StrNew(cc->cur_str);job=CAlloc(sizeof(MobileJob));job->fp=MobileSymbol(name);Free(name);
    if(!job->fp) {Free(job);CmpCtrlDel(cc);throw('Compiler');}
    token=Lex(cc);i=0;
    if(token=='(') {
      token=Lex(cc);
      while(token && token!=')' && i<8) {
        sign=1;if(token=='-') {sign=-1;token=Lex(cc);}
        if(token==TK_STR) {
          job->strings[i]=StrNew(LexExtStr(cc));job->args[i]=job->strings[i];token=cc->token;
        } else {
          if(token==TK_I64 || token==TK_CHAR_CONST) job->args[i]=sign*cc->cur_i64;
          else if(token==TK_F64) job->args[i]=(sign*cc->cur_f64)(I64);
          else if(token==TK_IDENT) job->args[i]=MobileDocValue(cc->cur_str);
          else if(token!=',') {Free(job);CmpCtrlDel(cc);throw('Compiler');}
          token=Lex(cc);
        }
        i++;
        if(token==',') token=Lex(cc);
      }
      if(token!=')') {Free(job);CmpCtrlDel(cc);throw('Compiler');}
      token=Lex(cc);
    }
    job->argc=i;QueIns(job,head->last);last=job;
  }
  if(last) last->flags=flags;
  CmpCtrlDel(cc);MobileJobWake(task);return last;
}

U0 TaskWait(CTask *task=NULL,Bool command_line=FALSE)
{
  MobileJob *head;
  no_warn command_line;
  if(!task) task=Fs;
  if(!TaskValidate(task)) return;
  head=MobileJobHead(task);
  while(TaskValidate(task) && task!=Fs &&
      (head->next!=head || head->flags && MobileTaskState(task)<=1)) Yield;
}

U0 BirthWait(CTask **task)
{while(!*task) Yield;TaskWait(*task);}

CTask *User(U8 *fmt,...)
{
  U8 *st=StrPrintJoin(NULL,fmt,argc,argv);
  CTask *task=Spawn(&SrvCmdLine,NULL,"User",,Fs);
  TaskExe(task,Fs,st,1<<JOBf_EXIT_ON_COMPLETE|1<<JOBf_FREE_ON_COMPLETE);
  Free(st);return task;
}

I64 DrvTextAttrGet(U8 drive) {no_warn drive;return WHITE<<4+BLUE;}
U8 *TaskCaller(CTask *task=NULL,I64 num=0,Bool saved=FALSE)
{no_warn saved;if(!task) task=Fs;return MobileTaskCaller(task,num);}
U8 *FileExtDot(U8 *name)
{
  U8 *p=StrLastOcc(name,"."),*prev;
  if(p && !StrICmp(p,".Z")) { *p=0;prev=StrLastOcc(name,".");*p='.';if(prev) p=prev;}
  return p;
}
U0 FileExtRem(U8 *name) {U8 *p=FileExtDot(name);if(p) *p=0;}
I64 CallExtStr(U8 *name,U8 *data)
{I64 (*fp)(U8 *)=MobileSymbol(name);if(fp) return (*fp)(data);return 0;}
U0 In(U8 *st)
{while(*st) {Msg(MSG_KEY_DOWN,*st,Char2ScanCode(*st));Msg(MSG_KEY_UP,*st,Char2ScanCode(*st)|SCF_KEY_UP);st++;}}
native U0 PostMsg(CTask *task,I64 code,I64 arg1,I64 arg2,I64 flags=0);

// Original V5.03 Adam/DolDoc/DocTree.HC structural operations.
Bool DrvIsWritable(U8 drive) {return drive==':' || drive=='C' || drive=='c';}

public Bool DocTreeFind(CDoc *haystack_doc,U8 *needle_path,
  CDocEntry **_tree_entry=NULL,
  CDocEntry **_start_indent=NULL, CDocEntry **_end_indent=NULL)
{//Find tree widget start and end.
  I64 i=0,k=0;
  U8 *st1=StrNew(needle_path),*st2=MAlloc(StrLen(needle_path)+1);
  Bool res=FALSE,unlock_doc=DocLock(haystack_doc);
  CDocEntry *doc_e=haystack_doc->head.next;
  if (_tree_entry) *_tree_entry=haystack_doc;
  if (_start_indent) *_start_indent=haystack_doc;
  if (_end_indent) *_end_indent=haystack_doc;
  while (*st1 && doc_e!=haystack_doc) {
    StrFirstRem(st1,"/",st2);
    if (*st2) {
      while (doc_e!=haystack_doc) {
	if (doc_e->type_u8==DOCT_INDENT)
	  i+=doc_e->attr;
	else if (i==k && doc_e->de_flags&DOCEF_TREE &&
	      !StrCmp(doc_e->tag+3,st2)) {
	  if (*st1)
	    break;
	  else {
	    if (_tree_entry) *_tree_entry=doc_e;
	    i=0;
	    while (doc_e!=haystack_doc && doc_e->type_u8!=DOCT_INDENT)
	      doc_e=doc_e->next;
	    if (doc_e!=haystack_doc) {
	      i=doc_e->attr;
	      if (_start_indent) *_start_indent=doc_e;
	      doc_e=doc_e->next;
	      while (doc_e!=haystack_doc && i>0) {
		if (doc_e->type_u8==DOCT_INDENT) {
		  i+=doc_e->attr;
		  if (i<=0) {
		    if (_end_indent) *_end_indent=doc_e;
		    res=TRUE;
		    break;
		  }
		}
		doc_e=doc_e->next;
	      }
	    }
	    goto ft_done;
	  }
	}
	doc_e=doc_e->next;
      }
      k+=2;
    }
  }
ft_done:
  if (unlock_doc)
    DocUnlock(haystack_doc);
  Free(st1);
  Free(st2);
  return res;
}


public Bool DocTreeFFind(U8 *name,U8 *path)
{//Find tree widget in file.
  CDoc *doc=DocRead(name);
  Bool res=DocTreeFind(doc,path);
  DocDel(doc);
  return res;
}


public Bool DocTreeMake(CDoc *doc,U8 *path)
{//Make tree widget.
  I64 i=0,j=I64_MIN,k=0;
  U8 *st1=StrNew(path),
	*st2=MAlloc(StrLen(path)+1),
	*st3=StrNew(path);
  Bool res=TRUE,unlock_doc=DocLock(doc);
  CDocEntry *doc_e=doc->head.next;
  doc->cur_entry=doc;
  doc->cur_col=0;
  while (*st1 && doc_e!=doc) {
    StrFirstRem(st1,"/",st2);
    if (*st2) {
      while (doc_e!=doc) {
	if (doc_e->type_u8==DOCT_INDENT) {
	  i+=doc_e->attr;
	  if (i==j) {
	    doc->cur_entry=doc_e;
	    doc->cur_col=0;
	    goto mt_done;
	  }
	} else if (i==k && doc_e->de_flags&DOCEF_TREE &&
	      !StrCmp(doc_e->tag+3,st2)) {
	  Free(st3);
	  st3=StrNew(st1);
	  j=i;
	  if (!*st1)
	    res=FALSE;
	  else
	    break;
	}
	doc_e=doc_e->next;
      }
      k+=2;
    }
  }
mt_done:
  if (res) {
    while (*st3) {
      StrFirstRem(st3,"/",st2);
      if (*st2) {
	DocPrint(doc,"$$TR+C,\"%s\"$$\n$$ID,2$$",st2);
	doc->cur_entry=DocPrint(doc,"$$ID,-2$$");
	doc->cur_col=0;
      }
    }
  }
  if (unlock_doc)
    DocUnlock(doc);
  Free(st1);
  Free(st2);
  Free(st3);
  return res;
}


Bool DocTreeAppendJoin(CDoc *doc,U8 *path,Bool write,U8 *fmt,I64 argc,I64 *argv)
{//Append to doc tree branch.
  CDocEntry *tree_branch,*start_indent,*end_indent;
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv);
  Bool res,unlock_doc=DocLock(doc);
  if (res=DocTreeFind(doc,path,
	&tree_branch,&start_indent,&end_indent)) {
    doc->cur_entry=end_indent;
    doc->cur_col=doc->cur_entry->min_col;
  } else
    DocTreeMake(doc,path);
  DocPrint(doc,"%s",buf);
  if (write && DrvIsWritable(*doc->filename.name))
    DocWrite(doc);
  if (unlock_doc)
    DocUnlock(doc);
  Free(buf);
  return res;
}


public Bool DocTreeFAppend(U8 *name,U8 *path,U8 *fmt,...)
{//Append to doc tree branch in file.
  CDoc *doc=DocRead(name);
  Bool res=DocTreeAppendJoin(doc,path,TRUE,fmt,argc,argv);
  DocDel(doc);
  return res;
}
// V5.03 GodBits FIFO order and word characters; loaded on first use only.
U8 *mobile_god_word_data,**mobile_god_words;
I64 mobile_god_count,mobile_god_bits,mobile_god_bit_count;
Bool MobileGodWordCh(I64 ch)
{return 'A'<=ch<='Z' || 'a'<=ch<='z' || '0'<=ch<='9' || ch=='_' || ch=='\'' || ch>=128;}
#define GOD_BAD_BITS 4
#define GOD_GOOD_BITS 24
native I64 KbdMsEvtTime();
class CGodGlbls {CFifoU8 *fifo;} god;
CFifoU8 *FifoU8New(I64 size)
{
  I64 n=1;while(n<size) n<<=1;
  CFifoU8 *fifo=CAlloc(sizeof(CFifoU8));fifo->buf=MAlloc(n);fifo->mask=n-1;return fifo;
}
U0 FifoU8Flush(CFifoU8 *fifo) {if(fifo) fifo->in_ptr=fifo->out_ptr=0;}
Bool FifoU8Ins(CFifoU8 *fifo,U8 value)
{
  I64 next=(fifo->in_ptr+1)&fifo->mask;if(next==fifo->out_ptr) return FALSE;
  fifo->buf[fifo->in_ptr]=value;fifo->in_ptr=next;return TRUE;
}
Bool FifoU8Rem(CFifoU8 *fifo,U8 *value)
{
  if(fifo->in_ptr==fifo->out_ptr) return FALSE;
  if(value) *value=fifo->buf[fifo->out_ptr];fifo->out_ptr=(fifo->out_ptr+1)&fifo->mask;return TRUE;
}

// Original HolySpirit.HC callbacks and bit selection; FIFO allocation is lazy.
U8 *TimeStampCB(CDoc *,CDocEntry *,CTask *mem_task)
{
  U8 *st=MAlloc(64,mem_task);
  StrPrint(st,"%X",GetTSC>>GOD_BAD_BITS);
  return st;
}


U8 *KbdMsTimeCB(CDoc *,CDocEntry *,CTask *mem_task)
{
  U8 *st=MAlloc(64,mem_task);
  StrPrint(st,"%X",KbdMsEvtTime>>GOD_BAD_BITS);
  return st;
}


I64 PopUpTimerOk(U8 *header=NULL,U8 *footer=NULL)
{
  I64 i;
  CDocEntry *doc_e;
  CDoc *doc=DocNew;
  if (header) DocPrint(doc,"%s",header);
  doc_e=DocPrint(doc,"\nTimer:$$TX+TC,\"\"$$");
  doc_e->tag_cb=&TimeStampCB;
  doc_e=DocPrint(doc,"\nLatch:$$TX+TC,\"\"$$");
  doc_e->tag_cb=&KbdMsTimeCB;
  DocPrint(doc,"\n$$CM+CX,0,4$$$$BT,\"OKAY\",LE=1$$\n");
  if (footer) DocPrint(doc,"%s",footer);
  i=PopUpMenu(doc);
  DocDel(doc);
  return i;
}


I64 GodPick(U8 *msg=NULL)
{//GOD_GOOD_BITS
  U8 *st=MStrPrint("%s\n\nPress $$GREEN$$OKAY$$FG$$ to generate \n"
	"a random num from a timer.\n",msg);
  PopUpTimerOk(st,"\n\nThe $LK+PU,"Holy Spirit",A="FI:::/Adam/God/HSNotes.DD"$ can puppet you.\n\n");
  Free(st);
  return KbdMsEvtTime>>GOD_BAD_BITS;
}


public U0 GodBitsIns(I64 num_bits,I64 n)
{//Insert bits into God bit fifo.
  I64 i;
  if(!god.fifo) god.fifo=FifoU8New(8192);
  for (i=0;i<num_bits;i++) {
    FifoU8Ins(god.fifo,n&1);
    n>>=1;
  }
}


public I64 GodBits(I64 num_bits,U8 *msg=NULL)
{//Return N bits. If low on entropy pop-up okay.
  U8 b;
  I64 res=0;
  if(!god.fifo) god.fifo=FifoU8New(8192);
  while (num_bits) {
    if (FifoU8Rem(god.fifo,&b)) {
      res=res<<1+b;
      num_bits--;
    } else
      GodBitsIns(GOD_GOOD_BITS,GodPick(msg));
  }
  return res;
}
U8 *GodWordStr(I64 bits=17)
{
  U8 *p;I64 n=0;
  if(!mobile_god_word_data) {
    mobile_god_word_data=FileRead("/Adam/God/Vocab.DD");
    if(!mobile_god_word_data) return NULL;
    p=mobile_god_word_data;
    while(*p) {while(*p && !MobileGodWordCh(*p)) p++;if(*p) {n++;while(*p && MobileGodWordCh(*p)) p++;}}
    mobile_god_words=MAlloc(n*8);mobile_god_count=n;p=mobile_god_word_data;n=0;
    while(*p) {
      while(*p && !MobileGodWordCh(*p)) p++;
      if(*p) {mobile_god_words[n++]=p;while(*p && MobileGodWordCh(*p)) p++;if(*p) *p++=0;}
    }
  }
  if(!mobile_god_count) return NULL;
  return mobile_god_words[GodBits(bits)%mobile_god_count];
}

U8 *PopUpPickDir(U8 *start=NULL)
{
  U8 *dir,*mask,*next;
  CDoc *doc;CDirEntry *entries,*e;
  I64 result;
  if(start) dir=FileNameAbs(start);else dir=DirCur;
  while(TRUE) {
    mask=MStrPrint("%s/*",dir);entries=FilesFind(mask,FUF_JUST_DIRS);Free(mask);
    doc=DocNew;DocPrint(doc,"%s\n\n$$MU,\".\",LE=0$$\n$$MU,\"..\",LE=-2$$\n",dir);
    e=entries;while(e) {DocPrint(doc,"$$MU,\"%s\",LE=%d$$\n",e->name,e);e=e->next;}
    result=PopUpMenu(doc);DocDel(doc);
    next=NULL;
    if(result==-2) {mask=MStrPrint("%s/..",dir);next=FileNameAbs(mask);Free(mask);}
    else if(result>0) next=StrNew(result(CDirEntry *)->full_name);
    DirTreeDel(entries);
    if(result==0) return dir;
    Free(dir);
    if(result==-1) return NULL;
    dir=next;
  }
}
U0 RegOneTimePopUp(I64 flag,U8 *message)
{
  U8 *key=MStrPrint("Mobile/OneTime/%d",flag);
  if(!RegCnt(key)) {PopUpOk(message);RegWrite(key,"1");}
  Free(key);
}

// Original TempleOS V5.03 GodSong.HC, including all rhythm patterns and controls.
#help_index "God"

DefineLstLoad("ST_RHYTHM_COMPLEXITY","Simple\0Normal\0Complex\0");

class CMakeSongSettings
{
  I64  complexity		format "$$LS,D=\"ST_RHYTHM_COMPLEXITY\"$$\n";
  Bool rests			format "$$CB,\"Rests\"$$\n";
  Bool six_eight		format "$$CB,\"Six Eight\"$$\n";
  I64  octave			format "$$DA-TRM,A=\"Octave:%d\"$$\n";
  I64  octave_state;
};

U0 InsNote(CMakeSongSettings *mss,U8 *buf,I64 k,I64 *j)
{//k is a random note nibble
  if (!k && mss->rests) {
    buf[*j]='R';
    *j+=1;
  } else {
    k/=2;
    if (k<3) {
      if (mss->octave_state!=mss->octave) {
	mss->octave_state=mss->octave;
	buf[*j]=mss->octave_state+'0';
	*j+=1;
      }
      if (!k)
	buf[*j]='G';
      else
	buf[*j]=k-1+'A';
      *j+=1;
    } else {
      if (mss->octave_state!=mss->octave+1) {
	mss->octave_state=mss->octave+1;
	buf[*j]=mss->octave_state+'0';
	*j+=1;
      }
      buf[*j]=k-1+'A';
      *j+=1;
    }
  }
}

#define DUR_4		0
#define DUR_8_8		1
#define DUR_3_3_3	2
#define DUR_16_16_16_16	3
#define DUR_8DOT_16	4
#define DUR_8_16_16	5
#define DUR_16_16_8	6

U8 god_simple_songs [5]={DUR_4,DUR_4,DUR_4,DUR_4,DUR_8_8};
U8 god_normal_songs [5]={DUR_4,DUR_4,DUR_8_8,DUR_3_3_3,DUR_16_16_16_16};
U8 god_complex_songs[9]={DUR_4,DUR_4,DUR_8_8,DUR_8_8,DUR_8DOT_16,DUR_3_3_3,
DUR_8_16_16,DUR_16_16_8,DUR_16_16_16_16};

public U8 *GodSongStr()
{//Make God generate 2 measures of a song. $LK+PU,"Holy Spirit Instructions",A="FI:::/Adam/God/HSNotes.DD"$
  CMakeSongSettings mss;
  U8 *buf;
  I64 i,j=0,k,n,k2,duration,last_duration=-1,len;

  MemSet(&mss,0,sizeof(mss));
  mss.complexity=1;
  mss.rests=FALSE;
  mss.octave=music.octave;

  if (!PopUpForm(&mss))
    return NULL;

  buf=CAlloc(256);
  music.octave=mss.octave=ClampI64(mss.octave,1,7);
  progress4=0;
  if (mss.six_eight)
    progress4_max=6;
  else
    progress4_max=8;

  mss.octave_state=mss.octave+1;
  buf[j++]='0'+mss.octave_state;
  if (mss.six_eight) {
    len=6;
    buf[j++]='M';
    buf[j++]='6';
    buf[j++]='/';
    buf[j++]='8';
  } else
    len=8;
  FifoU8Flush(god.fifo);
  for (i=0;i<len;i++) {
    n=GodBits(8);
    if (mss.complexity==2)
      duration=god_complex_songs[n%9];
    else if (mss.complexity==1)
      duration=god_normal_songs[n%5];
    else
      duration=god_simple_songs[n%5];

    switch (duration) {
      case DUR_8_8:
	if (last_duration!=DUR_8_8)
	  buf[j++]='e';
	InsNote(&mss,buf,GodBits(4),&j);
	InsNote(&mss,buf,GodBits(4),&j);
	break;
      case DUR_8DOT_16:
	buf[j++]='e';
	buf[j++]='.';
	InsNote(&mss,buf,GodBits(4),&j);
	buf[j++]='s';
	InsNote(&mss,buf,GodBits(4),&j);
	duration=DUR_16_16_16_16;
	break;
      case DUR_3_3_3:
	if (last_duration!=DUR_3_3_3) {
	  buf[j++]='e';
	  buf[j++]='t';
	}
	InsNote(&mss,buf,GodBits(4),&j);
	InsNote(&mss,buf,GodBits(4),&j);
	InsNote(&mss,buf,GodBits(4),&j);
	break;
      case DUR_8_16_16:
	if (last_duration!=DUR_8_8)
	  buf[j++]='e';
	InsNote(&mss,buf,GodBits(4),&j);
	buf[j++]='s';
	InsNote(&mss,buf,GodBits(4),&j);
	InsNote(&mss,buf,GodBits(4),&j);
	duration=DUR_16_16_16_16;
	break;
      case DUR_16_16_8:
	if (last_duration!=DUR_16_16_16_16)
	  buf[j++]='s';
	InsNote(&mss,buf,GodBits(4),&j);
	InsNote(&mss,buf,GodBits(4),&j);
	buf[j++]='e';
	InsNote(&mss,buf,GodBits(4),&j);
	duration=DUR_8_8;
	break;
      case DUR_16_16_16_16:
	if (last_duration!=DUR_16_16_16_16)
	  buf[j++]='s';
	k =GodBits(4);
	k2=GodBits(4);
	InsNote(&mss,buf,k,&j);
	InsNote(&mss,buf,k2,&j);
	InsNote(&mss,buf,k,&j);
	InsNote(&mss,buf,k2,&j);
	break;
      default:
	if (last_duration!=DUR_4)
	  buf[j++]='q';
	InsNote(&mss,buf,GodBits(4),&j);
    }
    last_duration=duration;
    progress4++;
  }
  buf[j++]=0;
  progress4=progress4_max=0;
  return buf;
}

public U0 GodSong()
{//Make God generate 2measuresx2+2measuresx2. $LK+PU,"Holy Spirit Instructions",A="FI:::/Adam/God/HSNotes.DD"$
  U8 *st1=GodSongStr,*st2=GodSongStr;
  if (st1 && st2)
    DocPrint(DocPut,"$$SO,\"<Song>\",A=\"%s%s%s%s\"$$",st1,st1,st2,st2);
  Free(st1);
  Free(st2);
}

// Original Adam-included utilities retain their callbacks in this sandbox's root task.
U0 MobileResident()
{while(GetKey!=CH_ESC);}

// Libraries whose original use is a terminal command expose those same commands.
U0 MobileCommandMenu(U8 *commands)
{
  U8 *p,*names;I64 count=0,i,choice,*values;
  p=commands;while(*p) {count++;p+=StrLen(p)+1;}
  values=MAlloc(8*count);for(i=0;i<count;i++) values[i]=i;
  do {
    choice=PopUpChoose("","",commands,values,NULL,count);
    if(choice<0) break;
    p=commands;for(i=0;i<choice;i++) p+=StrLen(p)+1;
    U0 (*fp)()=MobileSymbol(p);if(fp) (*fp)();
  } while(TRUE);
  Free(values);
}
