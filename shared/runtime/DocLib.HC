U8 *MStrUtil(U8 *src,I64 flags)
{return StrUtil(StrNew(src),flags);}

CDate local_time_offset=0;
CDate Struct2Date(CDateStruct *ds)
{
  I64 y=ds->year,m=ds->mon,era,yoe,doy,days;
  CDate result;
  while(m<1) {m+=12;y--;}
  while(m>12) {m-=12;y++;}
  if(m<=2) y--;
  if(y>=0) era=y/400;else era=(y-399)/400;
  yoe=y-era*400;
  if(m>2) m-=3;else m+=9;
  doy=(153*m+2)/5+ds->day_of_mon-1;
  days=era*146097+yoe*365+yoe/4-yoe/100+doy+60;
  result.date=days;
  result.time=(ds->sec10000+100*(ds->sec100+100*(ds->sec+60*(ds->min+60*ds->hour))))(U64)*0x100000000/864000000;
  return result;
}
I64 FirstDayOfMon(I64 i)
{//First day of month, given 32-bit day since AD 0.
  CDateStruct ds;
  CDate cdt=0;
  cdt.date=i;
  Date2Struct(&ds,cdt);
  ds.day_of_mon=1;
  cdt=Struct2Date(&ds);
  return cdt.date;
}

I64 LastDayOfMon(I64 i)
{//Last day of month, given 32-bit day since AD 0.
  CDateStruct ds;
  CDate cdt=0;
  cdt.date=i;
  Date2Struct(&ds,cdt);
  ds.mon++;
  if (ds.mon==13) {
    ds.mon=0;
    ds.year++;
  }
  ds.day_of_mon=1;
  cdt=Struct2Date(&ds);
  return cdt.date-1;
}

I64 FirstDayOfYear(I64 i)
{//First day of year, given 32-bit day since AD 0.
  CDateStruct ds;
  CDate cdt=0;
  cdt.date=i;
  Date2Struct(&ds,cdt);
  ds.day_of_mon=1;
  ds.mon=1;
  cdt=Struct2Date(&ds);
  return cdt.date;
}

I64 LastDayOfYear(I64 i)
{//Last day of year, given 32-bit day since AD 0.
  CDateStruct ds;
  CDate cdt=0;
  cdt.date=i;
  Date2Struct(&ds,cdt);
  ds.day_of_mon=1;
  ds.mon=1;
  ds.year++;
  cdt=Struct2Date(&ds);
  return cdt.date-1;
}
CDate Str2Date(U8 *_src)
{/*"*+nnnn", "*-nnnn", "mm/dd", "mm/dd/yy"
It also supports some funs
SM() start of mon
EM() end of mon
SY() start of year
EY() end of year
Full expressions are not implimented
but you can do stuff like SM(*-7)+3
and it will return the 3rd day after
the start of mon for seven days before
today.
*/
  CDate res=0;
  CDateStruct ds,ds_now;
  U8 *src=MStrUtil(_src,SUF_REM_SPACES|SUF_TO_UPPER),
	*v=StrNew(src),
	*ptr=src;
  Bool start_mon=FALSE,end_mon=FALSE,
	start_year=FALSE,end_year=FALSE;

  MemSet(&ds,0,sizeof(CDateStruct));
  if (!StrNCmp(ptr,"SM(",3)) {
    ptr+=3;
    start_mon=TRUE;
  } else if (!StrNCmp(ptr,"EM(",3)) {
    ptr+=3;
    end_mon=TRUE;
  } else if (!StrNCmp(ptr,"SY(",3)) {
    ptr+=3;
    start_year=TRUE;
  } else if (!StrNCmp(ptr,"EY(",3)) {
    ptr+=3;
    end_year=TRUE;
  }
  if (*ptr=='*') {
    ptr++;
    if (*ptr=='+' || *ptr=='-')
      res.date=Str2I64(ptr,,&ptr);
    res+=Now+local_time_offset;
  } else {
    StrFirstRem(ptr,"/",v); //Put mon into v
    ds.mon=Str2I64(v);
    if (StrOcc(ptr,'/')) {
      StrFirstRem(ptr,"/",v); //Put day into v leaving year in ptr
      ds.day_of_mon=Str2I64(v);
      ds.year=Str2I64(ptr,,&ptr);
      if (ds.year<100) //if not 4 digit year
	ds.year+=2000;
    } else {
      ds.day_of_mon=Str2I64(ptr,,&ptr);
      Date2Struct(&ds_now,Now+local_time_offset);
      ds.year=ds_now.year;
    }
    res=Struct2Date(&ds);
  }
  if (*ptr==')') ptr++;

  if (start_mon)
    res.date=FirstDayOfMon(res.date);
  else if (end_mon)
    res.date=LastDayOfMon(res.date);
  else if (start_year)
    res.date=FirstDayOfYear(res.date);
  else if (end_year)
    res.date=LastDayOfYear(res.date);

  if (*ptr=='+' || *ptr=='-')
    res.date+=Str2I64(ptr);
  Free(src);
  Free(v);
  return res-local_time_offset;
}

// Original Kernel/KHashA.HC hash recurrence, with explicit carry on overflow.
I64 HashStr(U8 *st)
{
  U64 h=0,carry,old;
  if (!st) return 0;
  while (*st) {carry=h>>63;h=h<<1+*st++ +carry;}
  old=h>>16;return h+old+((h>>15)&1);
}
CHashTable *HashTableNew(I64 size,CTask *task=NULL)
{CHashTable *r=CAlloc(sizeof(CHashTable),task);r->body=CAlloc(size*8,task);r->mask=size-1;return r;}
CHash *HashFind(U8 *name,CHashTable *table,I64 mask=I64_MAX,I64 instance=1)
{
  CHash *h;
  while (table) {
    h=table->body[HashStr(name)&table->mask];
    while (h) {if ((h->type&mask) && !StrCmp(name,h->str) && !--instance) return h;h=h->next;}
    table=table->next;
  }
  return NULL;
}
U0 HashAdd(CHash *h,CHashTable *table)
{I64 n=HashStr(h->str)&table->mask;h->next=table->body[n];table->body[n]=h;}
I64 LinkedLstCnt(CQue *q)
{I64 n=0;while(q) {n++;q=q->next;}return n;}
I64 PopUpColorLighting(U8 *header=NULL);

// Mobile DolDoc compatibility. Original V5.03 structures, editable linked entries,
// callbacks and forms; no original application source is rewritten.
native U0 MobileDocEmit(U8 *st);
native U0 MobileDocOrigin(CDoc *doc);
native U0 MobileDocForget(CDoc *doc);
native Bool MobileDocCapture(Bool enabled);
native U8 *ACAlloc(I64 size);
native U8 *MobileDocFields(U8 *class_name);
native I64 MobileDocValue(U8 *expr,I64 dft=0);
native CDC *MobileGRRead(U8 *filename);
native I64 MobileGRWrite(U8 *filename,CDC *dc,I64 flags);
native CDC *DCScrnCapture(Bool include_zoom=TRUE,CTask *task=NULL);
Bool PopUpForm(U8 *data,U8 *class_name=lastclass);

CDoc *DocNew(U8 *filename=NULL,CTask *task=NULL)
{
  CDoc *doc=CAlloc(sizeof(CDoc));
  if (!task) task=Fs;
  QueInit(doc);
  QueInit(&doc->bin_head);
  doc->cur_entry=doc;
  doc->win_task=doc->mem_task=doc->owning_task=task;
  doc->max_entries=2000;MobileDocOrigin(doc);
  if (filename) StrCpy(doc->filename.name,filename);else StrCpy(doc->filename.name,"~/Tmp.DD.Z");
  return doc;
}

CDoc *DocPut(CTask *task=NULL)
{
  if (!task) task=Fs;
  if (!task->put_doc) task->put_doc=DocNew(,task);
  if (!task->display_doc) task->display_doc=task->put_doc;
  return task->put_doc;
}

U0 DocEntryDel(CDoc *doc,CDocEntry *e)
{
  if (!e || e==doc) return;
  if (doc->cur_entry==e) doc->cur_entry=e->next;
  QueRem(e);
  Free(e->tag);Free(e->left_macro);Free(e->right_macro);
  Free(e->define_str);Free(e->aux_str);Free(e);
}

U0 MobileDocEmpty(CDoc *doc)
{
  if (!doc) return;
  while (doc->head.next!=doc) DocEntryDel(doc,doc->head.next);
  doc->cur_entry=doc;doc->cur_col=0;doc->line=doc->col=0;
}

U0 DocDel(CDoc *doc)
{
  if (!doc) return;
  MobileDocForget(doc);MobileDocEmpty(doc);while(doc->bin_head.next!=&doc->bin_head) {CDocBin *b=doc->bin_head.next;QueRem(b);Free(b->data);Free(b->tag);Free(b);}
  Free(doc);
}

U0 MobileDocClear(CTask *task=NULL)
{
  if (!task) task=Fs;
  if (task && task->put_doc) MobileDocEmpty(task->put_doc);
}

U8 *MobileDocArg(U8 *cmd,U8 *key)
{
  U8 *p=StrFind(key,cmd),*end,*r;
  I64 n;
  if (!p) return NULL;
  p+=StrLen(key);
  if (*p=='\"') {
    p++;end=p;
    while (*end && *end!='\"') end++;
  } else {
    end=p;while (*end && *end!=',') end++;
  }
  n=end-p;r=MAlloc(n+1);MemCpy(r,p,n);r[n]=0;
  return r;
}

CDocEntry *MobileDocEntry(CDoc *doc,I64 type,U8 *tag)
{
  I64 count=0;CDocEntry *scan=doc->head.next;
  while(scan!=doc && count<2000) {count++;scan=scan->next;}
  if(count>=MinI64(MaxI64(doc->max_entries,1),2000) && doc->head.next!=doc) DocEntryDel(doc,doc->head.next);
  CDocEntry *e=CAlloc(sizeof(CDocEntry));
  e->type=type;e->tag=StrNew(tag);e->len=StrLen(tag);
  e->x=doc->col;e->y=doc->line;
  if (!doc->cur_entry) doc->cur_entry=doc;
  QueIns(e,doc->cur_entry->last);
  if (type==DOCT_NEW_LINE) {doc->line++;doc->col=0;}
  else doc->col+=e->len;
  return e;
}

CDocEntry *MobileDocAppend(CDoc *doc,U8 *st)
{
  CDocEntry *res=NULL,*e;
  U8 *p=st,*begin,*cmd,*tag,*v,*raw;
  I64 n,type,color=doc->head.type.u8[1]&15;
  while (*p) {
    if (*p=='\n') {
      MobileDocEntry(doc,DOCT_NEW_LINE,"");p++;
    } else if (*p=='$$' && p[1]=='$$' && !(doc->flags&DOCF_PLAIN_TEXT)) {
      e=MobileDocEntry(doc,DOCT_TEXT|color<<8,"$$");e->aux_str=StrNew("$$$$");p+=2;
    } else if (*p=='$$' && !(doc->flags&DOCF_PLAIN_TEXT)) {
      begin=++p;while (*p && *p!='$$') p++;
      n=p-begin;cmd=MAlloc(n+1);MemCpy(cmd,begin,n);cmd[n]=0;
      if (*p) p++;
      raw=MStrPrint("$$%s$$",cmd);
      if (!StrNCmp(cmd,"FG,",3)) {color=Str2I64(cmd+3)&15;doc->head.type.u8[1]=color;e=MobileDocEntry(doc,DOCT_FOREGROUND|color<<8,"");e->attr=color;e->aux_str=StrNew(raw);}
      else if (LstMatch(cmd,Define("ST_COLORS"))>=0) {color=LstMatch(cmd,Define("ST_COLORS"));doc->head.type.u8[1]=color;e=MobileDocEntry(doc,DOCT_FOREGROUND|color<<8,"");e->attr=color;e->aux_str=StrNew(raw);}
      else if (!StrNCmp(cmd,"ID,",3)) {e=MobileDocEntry(doc,DOCT_INDENT,"");e->attr=Str2I64(cmd+3);e->aux_str=StrNew(raw);}
      else if (!StrNCmp(cmd,"TR",2)) {
        tag=MobileDocArg(cmd,",");v=MStrPrint("   %s",tag);Free(tag);
        e=MobileDocEntry(doc,DOCT_TREE,v);Free(v);e->de_flags|=DOCEF_TREE;e->aux_str=StrNew(raw);
      }
      else if (!StrNCmp(cmd,"MU",2) || !StrNCmp(cmd,"BT",2) ||
          !StrNCmp(cmd,"TX",2) || !StrNCmp(cmd,"LK",2) || !StrNCmp(cmd,"MA",2)) {
        type=DOCT_TEXT;
        if (!StrNCmp(cmd,"MU",2) || !StrNCmp(cmd,"BT",2)) type=DOCT_MENU_VAL;
        tag=MobileDocArg(cmd,",");
        if (!tag) {
          begin=StrFind("\"",cmd);
          if (begin) {begin++;tag=StrNew(begin);v=StrFirstOcc(tag,"\"");if (v) *v=0;}
        }
        e=MobileDocEntry(doc,type,tag);e->aux_str=StrNew(raw);res=e;Free(tag);
        v=MobileDocArg(cmd,",LE=");
        e->left_exp=MobileDocValue(v,doc->updates_cnt++);Free(v);
        v=MobileDocArg(cmd,",U=");e->user_data=MobileDocValue(v);Free(v);
        e->left_macro=MobileDocArg(cmd,",LM=");
      }
      else {e=MobileDocEntry(doc,DOCT_FOREGROUND,"");e->aux_str=StrNew(raw);}
      Free(raw);Free(cmd);
    } else {
      begin=p;while (*p && *p!='\n' && (*p!='$$' || doc->flags&DOCF_PLAIN_TEXT)) p++;
      n=p-begin;tag=MAlloc(n+1);MemCpy(tag,begin,n);tag[n]=0;
      e=MobileDocEntry(doc,DOCT_TEXT|color<<8,tag);Free(tag);
      if (!res) res=e;
    }
  }
  return res;
}

public CDocEntry *DocPrint(CDoc *doc,U8 *fmt,...)
{
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv);
  CDocEntry *res;
  if (!doc) doc=DocPut;
  res=MobileDocAppend(doc,buf);
  if (doc==Fs->put_doc) MobileDocEmit(buf);
  Free(buf);return res;
}

Bool DocLock(CDoc *doc) {return !LBts(&doc->locked_flags,0);}
U0 DocUnlock(CDoc *doc) {LBtr(&doc->locked_flags,0);}
U0 DocMax(CTask *task=NULL) {DocPut(task);}
U0 DocCenter(CDoc *doc) {doc->top_line_num=MaxI64(0,doc->cur_entry->y-20);}

U0 DocRecalc(CDoc *doc)
{
  CDocEntry *e=doc->head.next;
  I64 x=0,y=0;
  while (e!=doc) {
    e->x=x;e->y=y;
    if (e->type_u8==DOCT_NEW_LINE) {y++;x=0;} else x+=StrLen(e->tag);
    e=e->next;
  }
}

U0 MobileDocShow(CDoc *doc)
{
  CDocEntry *e=doc->head.next;
  U8 *st;
  MobileDocEmit("$$CL$$");
  while (e!=doc) {
    if (e->type_u8==DOCT_NEW_LINE) MobileDocEmit("\n");
    else {
      if (e->tag_cb) {
        st=(*e->tag_cb)(doc,e,Fs);MobileDocEmit(st);Free(st);
      } else MobileDocEmit(e->tag);
    }
    e=e->next;
  }
}

CDocEntry *MobileDocSprite(U8 *elems,U8 *fmt=NULL)
{
  CDoc *doc=DocPut;CDocBin *bin=CAlloc(sizeof(CDocBin));
  bin->num=++doc->cur_bin_num;bin->size=SpriteSize(elems);bin->data=MAlloc(bin->size);
  MemCpy(bin->data,elems,bin->size);bin->use_cnt=1;QueIns(bin,doc->bin_head.last);
  CDocEntry *e=MobileDocEntry(doc,DOCT_SPRITE,"");
  e->bin_data=bin;e->bin_num=bin->num;e->de_flags|=DOCEF_HAS_BIN;
  if(fmt) e->aux_str=MStrPrint(fmt,bin->num);
  else e->aux_str=MStrPrint("$$SP,\"\",BI=%d$$",bin->num);
  return e;
}

CDoc *DocRead(U8 *name,I64 flags=0)
{
  CDoc *doc=DocNew(name);
  I64 size,n,left;CDocBin *bin;
  U8 *data=FileRead(name,&size),*p;
  doc->flags=flags;
  if (data) {
    n=StrLen(data);
    if(n<size) {
      p=data+n+1;left=size-n-1;
      while(left>=16) {
        if(p(U32 *)[2]>left-16) throw('BadDoc');
        bin=CAlloc(sizeof(CDocBin));MemCpy(&bin->start,p,16);p+=16;left-=16;
        bin->data=MAlloc(bin->size);MemCpy(bin->data,p,bin->size);p+=bin->size;left-=bin->size;
        doc->cur_bin_num=MaxI64(doc->cur_bin_num,bin->num);QueIns(bin,doc->bin_head.last);
      }
    }
    MobileDocAppend(doc,data);Free(data);
  }
  doc->cur_entry=doc->head.next;return doc;
}

Bool DocWrite(CDoc *doc,Bool prompt=FALSE)
{
  CDocEntry *e=doc->head.next;
  I64 size=1,color=0,c;CDocBin *bin;
  U8 *buf,*p;
  if(prompt && !PopUpForm(&doc->filename)) return FALSE;
  while (e!=doc) {size+=StrLen(e->tag)+StrLen(e->aux_str)+24;e=e->next;}
  bin=doc->bin_head.next;while(bin!=&doc->bin_head) {size+=16+bin->size;bin=bin->next;}
  buf=CAlloc(size);p=buf;e=doc->head.next;
  while (e!=doc) {
    if (e->aux_str) {StrCpy(p,e->aux_str);p+=StrLen(p);if(e->type_u8==DOCT_FOREGROUND) color=e->attr;}
    else if (e->type_u8==DOCT_NEW_LINE) *p++='\n';
    else {
      c=e->type.u8[1]&15;
      if (!(doc->flags&DOCF_PLAIN_TEXT) && c!=color) {StrPrint(p,"$$FG,%d$$",c);p+=StrLen(p);color=c;}
      StrCpy(p,e->tag);p+=StrLen(e->tag);
    }
    e=e->next;
  }
  if(doc->bin_head.next!=&doc->bin_head) {
    *p++=0;bin=doc->bin_head.next;
    while(bin!=&doc->bin_head) {MemCpy(p,&bin->start,16);p+=16;MemCpy(p,bin->data,bin->size);p+=bin->size;bin=bin->next;}
  }
  size=FileWrite(doc->filename.name,buf,p-buf);Free(buf);return size>=0;
}

U0 DocGoToLine(CDoc *doc,I64 line)
{
  DocRecalc(doc);doc->cur_entry=doc->head.next;
  while (doc->cur_entry!=doc && doc->cur_entry->y<line-1)
    doc->cur_entry=doc->cur_entry->next;
  doc->cur_col=0;
}

I64 MobileDocMenu(CDoc *doc)
{
  CDoc *old_put=Fs->put_doc,*old_display=Fs->display_doc;
  CDocEntry *e=doc->head.next,*best;
  I64 code,ch,sc,i,d,best_d,result=DOCM_CANCEL;
  Fs->put_doc=Fs->display_doc=doc;DocRecalc(doc);
  while(e!=doc && e->type_u8!=DOCT_MENU_VAL) e=e->next;
  doc->cur_entry=e;MobileDocShow(doc);
  try {
    while(TRUE) {
      code=GetMsg(&ch,&sc,1<<MSG_KEY_DOWN|1<<MSG_MS_L_DOWN);
      if(code==MSG_MS_L_DOWN) {
        best=NULL;best_d=I64_MAX;e=doc->head.next;
        while(e!=doc) {
          if(e->type_u8==DOCT_MENU_VAL && e->y==sc/FONT_HEIGHT) {
            d=AbsI64(ch/FONT_WIDTH-e->x);
            if(d<best_d) {best_d=d;best=e;}
          }
          e=e->next;
        }
        if(!best) continue;doc->cur_entry=best;ch=CH_SPACE;sc=0;
      }
      e=doc->cur_entry;
      if(!ch && (sc&0x7F==SC_CURSOR_RIGHT || sc&0x7F==SC_CURSOR_DOWN)) {
        do e=e->next;while(e!=doc && e->type_u8!=DOCT_MENU_VAL);
        if(e!=doc) doc->cur_entry=e;continue;
      }
      if(!ch && (sc&0x7F==SC_CURSOR_LEFT || sc&0x7F==SC_CURSOR_UP)) {
        do e=e->last;while(e!=doc && e->type_u8!=DOCT_MENU_VAL);
        if(e!=doc) doc->cur_entry=e;continue;
      }
      if(ch==CH_SHIFT_ESC) break;
      if((*doc->user_put_key)(doc,doc->user_put_data,ch,sc)) {MobileDocShow(doc);continue;}
      if(ch==CH_SPACE || ch=='\n') {
        (*doc->user_put_key)(doc,doc->user_put_data,CH_ESC,0);
        if(e!=doc) result=e->left_exp;break;
      }
      if(ch==CH_ESC) {if(e!=doc) result=e->left_exp;break;}
    }
  } catch {Fs->put_doc=old_put;Fs->display_doc=old_display;throw;}
  Fs->put_doc=old_put;Fs->display_doc=old_display;return result;
}

I64 PopUpMenu(CDoc *doc,I64 flags=0)
{
  CDocEntry *e=doc->head.next;
  I64 count=0,i=0,res,*values;
  U8 *labels,*p,*header;
  no_warn flags;
  if(doc->user_put_key) return MobileDocMenu(doc);
  while (e!=doc) {if (e->type_u8==DOCT_MENU_VAL) count++;e=e->next;}
  if (!count) return DOCM_CANCEL;
  labels=CAlloc(1);e=doc->head.next;
  while (e!=doc) {if (e->type_u8==DOCT_MENU_VAL) i+=StrLen(e->tag)+1;e=e->next;}
  Free(labels);labels=p=CAlloc(i+1);values=MAlloc(count*8);e=doc->head.next;i=0;
  while (e!=doc) {
    if (e->type_u8==DOCT_MENU_VAL) {
      StrCpy(p,e->tag);p+=StrLen(p)+1;values[i++]=e->left_exp;
    }
    e=e->next;
  }
  header=CAlloc(1);e=doc->head.next;
  while(e!=doc) {
    if(e->type_u8!=DOCT_MENU_VAL) {
      if(e->type_u8==DOCT_NEW_LINE) {p=MStrPrint("%s\n",header);Free(header);header=p;}
      else if(e->tag && StrLen(header)+StrLen(e->tag)<2048) {p=MStrPrint("%s%s",header,e->tag);Free(header);header=p;}
    }
    e=e->next;
  }
  res=PopUpChoose(header,"",labels,values,NULL,count);Free(header);
  Free(labels);Free(values);return res;
}

I64 DocMenu(CDoc *doc=NULL,I64 flags=0)
{if (!doc) doc=DocPut;return PopUpMenu(doc,flags);}

U0 MobileDocEditChar(CDoc *doc,I64 ch)
{
  CDocEntry *e=doc->cur_entry,*next;
  U8 *s,*tail;
  I64 n,col=doc->cur_col;
  if(e==doc || e->type_u8!=DOCT_TEXT) {
    if(ch<32 && ch!='\n') return;
    e=MobileDocEntry(doc,DOCT_TEXT,"");doc->cur_entry=e;col=0;
  }
  n=StrLen(e->tag);col=ClampI64(col,0,n);
  if(ch==CH_BACKSPACE) {
    if(col) {MemCpy(e->tag+col-1,e->tag+col,n-col+1);col--;}
  } else if(ch=='\n') {
    tail=StrNew(e->tag+col);e->tag[col]=0;
    doc->cur_entry=e->next;MobileDocEntry(doc,DOCT_NEW_LINE,"");
    next=MobileDocEntry(doc,DOCT_TEXT,tail);Free(tail);doc->cur_entry=next;col=0;
  } else if(32<=ch<=255 && n<1023) {
    s=MAlloc(n+2);MemCpy(s,e->tag,col);s[col]=ch;MemCpy(s+col+1,e->tag+col,n-col+1);
    Free(e->tag);e->tag=s;col++;
  }
  doc->cur_col=col;DocRecalc(doc);MobileDocShow(doc);
}

U0 PutKey(I64 ch,I64 sc=0)
{
  CDoc *doc=DocPut;
  if (doc->user_put_key && (*doc->user_put_key)(doc,doc->user_put_data,ch,sc)) return;
  if (!(doc->flags&DOCF_FORM)) {MobileDocEditChar(doc,ch);return;}
  if (ch==CH_SPACE && doc->cur_entry!=doc && doc->cur_entry->left_exp)
    Msg(MSG_KEY_DOWN,doc->cur_entry->left_exp,0);
}

public Bool View()
{
  I64 ch,sc;
  CDoc *doc=DocPut;
  if(doc->cur_entry==doc) doc->cur_entry=doc->head.next;
  MobileDocShow(doc);
  do {
    ch=GetKey(&sc);
    if (sc&0x7F==SC_CURSOR_DOWN) {
      if (doc->cur_entry->next!=doc) doc->cur_entry=doc->cur_entry->next;
    } else if (sc&0x7F==SC_CURSOR_UP) {
      if (doc->cur_entry->last!=doc) doc->cur_entry=doc->cur_entry->last;
    } else if (ch!=CH_ESC && ch!=CH_SHIFT_ESC) PutKey(ch,sc);
    doc=DocPut;
  } while (ch!=CH_ESC && ch!=CH_SHIFT_ESC);
  return ch==CH_ESC;
}

Bool DocEd(CDoc *doc=NULL,I64 flags=0)
{no_warn flags;if (doc) {Fs->put_doc=doc;Fs->display_doc=doc;}return View;}

Bool PopUpEd(U8 *filename,CTask *parent=NULL,I64 flags=0)
{
  CDoc *old=DocPut,*old_display=Fs->display_doc,*doc=DocRead(filename,DOCF_PLAIN_TEXT);
  Bool result;
  no_warn parent;no_warn flags;
  Fs->put_doc=Fs->display_doc=doc;result=View;
  if(result) DocWrite(doc);
  Fs->put_doc=old;Fs->display_doc=old_display;DocDel(doc);MobileDocShow(old);
  return result;
}

// Lastclass is resolved by the compiler and retained by the native symbol image.
// Format metadata provides offsets and scalar/array widths without guessing layouts.
Bool DocForm(U8 *data,U8 *class_name=lastclass)
{
  Bool old_capture=MobileDocCapture(FALSE);
  U8 *fields=MobileDocFields(class_name),*p=fields,*fmt,*name,*value,*buf;
  I64 off,kind,size,ch,sc,n,index=0,cnt=0,i,selected=0,visible,first,choice;
  U8 *records[128],edit[512],*list_name;Bool dirty=FALSE;
  while (*p && cnt<128) {
    records[cnt++]=p;p+=StrLen(p)+1;p+=StrLen(p)+1;p+=StrLen(p)+1;
  }
  if (!cnt) {Free(fields);MobileDocCapture(old_capture);return FALSE;}
  *edit=0;
  while (TRUE) {
    MobileDocEmit("$$CL$$");
    visible=MaxI64(1,Fs->win_height-6);first=MaxI64(0,selected-visible+1);
    for (i=first;i<MinI64(cnt,first+visible);i++) {
      p=records[i];off=Str2I64(p,,&p);p++;kind=Str2I64(p,,&p);p++;size=Str2I64(p);
      name=records[i]+StrLen(records[i])+1;fmt=name+StrLen(name)+1;
      if (i==selected) "$$IV,1$$";
      "%s: ",name;
      if (i==selected && dirty) "%s",edit;
      else if (kind==2) "%s",data+off;
      else if (kind==1) "%g",* (data+off)(F64 *);
      else if (size==1) "%d",* (data+off)(U8 *);
      else if (size==2) "%d",* (data+off)(U16 *);
      else if (size==4) "%d",* (data+off)(I32 *);
      else "%d",* (data+off)(I64 *);
      "$$IV,0$$\n";
    }
    "\nESC: Save  SHIFT-ESC: Cancel  ENTER/TAB: Next\n";
    ch=GetKey(&sc);
    if (ch==CH_SHIFT_ESC) {Free(fields);MobileDocCapture(old_capture);return FALSE;}
    p=records[selected];off=Str2I64(p,,&p);p++;kind=Str2I64(p,,&p);p++;size=Str2I64(p);
    name=records[selected]+StrLen(records[selected])+1;fmt=name+StrLen(name)+1;
    if(ch==CH_SPACE && StrFind("CB,",fmt)) {
      data[off]=!data[off];dirty=FALSE;*edit=0;continue;
    }
    if(ch==CH_SPACE && StrFind("LS,",fmt)) {
      list_name=MobileDocArg(fmt,",D=");choice=PopUpPickLst(Define(list_name));Free(list_name);
      if(choice>=0) {StrPrint(edit,"%d",choice);dirty=TRUE;}
      continue;
    }
    if (ch=='\n' || ch=='\t' || ch==CH_ESC || (sc&0x7F)==SC_CURSOR_DOWN || (sc&0x7F)==SC_CURSOR_UP) {
      if (dirty) {
        if(StrFind("LS,",fmt)) {
          list_name=MobileDocArg(fmt,",D=");n=DefineCnt(list_name);Free(list_name);
          if(!(0<=Str2I64(edit)<n)) continue;
        }
        if (kind==2) {n=MinI64(size-1,StrLen(edit));MemCpy(data+off,edit,n);data[off+n]=0;}
        else if (kind==1) *(data+off)(F64 *)=Str2F64(edit);
        else if (size==1) *(data+off)(U8 *)=Str2I64(edit);
        else if (size==2) *(data+off)(U16 *)=Str2I64(edit);
        else if (size==4) *(data+off)(I32 *)=Str2I64(edit);
        else *(data+off)(I64 *)=Str2I64(edit);
      }
      if (ch==CH_ESC) {Free(fields);MobileDocCapture(old_capture);return TRUE;}
      if ((sc&0x7F)==SC_CURSOR_UP) selected=(selected+cnt-1)%cnt;
      else selected=(selected+1)%cnt;
      dirty=FALSE;*edit=0;
    } else if (ch==CH_BACKSPACE) {
      n=StrLen(edit);if (n) edit[n-1]=0;dirty=TRUE;
    } else if (32<=ch<127 && StrLen(edit)<MinI64(511,size-1+(kind!=2)*500)) {
      n=StrLen(edit);edit[n]=ch;edit[n+1]=0;dirty=TRUE;
    }
  }
}

Bool PopUpForm(U8 *data,U8 *class_name=lastclass) {return DocForm(data,class_name);}
I64 GRWrite(U8 *name,CDC *dc,I64 flags=DCSF_COMPRESSED) {return MobileGRWrite(name,dc,flags);}
CDC *GRRead(U8 *name,CTask *task=NULL) {no_warn task;return MobileGRRead(name);}
I64 GRScrnCaptureWrite(U8 *name,Bool zoom=TRUE)
{CDC *dc=DCScrnCapture(zoom);I64 n=GRWrite(name,dc,DCSF_PALETTE_GET);DCDel(dc);return n;}
U0 GRScrnCaptureRead(U8 *name)
{CDC *dc=GRRead(name);if (dc) {GrBlot(gr.dc,0,0,dc);DCDel(dc);}}

// Dictionary output from original V5.03 Adam/AutoComplete/ACFill.HC.
native U8 *ACDDefGet(U8 *word,I64 def_num=1);
native U8 *ACDDefsGet(U8 *word);
public U0 ACDDefsPut(CDoc *doc=NULL,U8 *st,I64 num=-1)
{//Put to doc a dictionary definition(s) of a word.
  U8 *st2,*st3;
  I64 ch,i=0;
  if (!st) return;
  if (*st==ACD_WORD_CHAR)
    st++;
  DocPrint(doc,"$$WW,1$$$$RED$$%s:$$FG$$\n\n",st);
  if (num<0) {
    if (st3=ACDDefsGet(st)) {
      st2=st3;
      while (ch=*st2++) {
	switch (ch) {
	  case ACD_WORD_CHAR:
	    break;
	  case ACD_DEF_CHAR:
	    DocPrint(doc,"$$GREEN$$(%d)$$FG$$ %s\n",
		  ++i,st2);
	    break;
	  case ACD_PRONUNCIATION_CHAR:
	    DocPrint(doc,"$$LTGREEN$$%s$$FG$$\n",st2);
	    break;
	  case ACD_POS_CHAR:
	    DocPrint(doc,"$$BLACK$$%s$$FG$$\n",st2);
	    break;
	  case ACD_EXTRA_CHAR:
	    DocPrint(doc,"$$LTBLUE$$%s$$FG$$\n",st2);
	    break;
	}
	st2+=StrLen(st2)+1;
      }
      Free(st3);
    }
  } else {
    while (st2=ACDDefGet(st,++i)) {
      if (i==num)
	DocPrint(doc,"$$GREEN$$(%d)$$FG$$ %s\n",
	      i,st2);
      Free(st2);
    }
  }
}

U0 ACDPopUpDef(U8 *word,I64 num=-1,CTask *parent=NULL)
{
  no_warn parent;CDoc *old=DocPut,*doc=DocNew;
  Fs->put_doc=Fs->display_doc=doc;
  ACDDefsPut(doc,word,num);View;
  Fs->put_doc=Fs->display_doc=old;DocDel(doc);
}

// Original V5.03 Adam/DolDoc/DocGr.HC color/lighting chooser.
public I64 PopUpColorLighting(U8 *header=NULL)
{//Chooser for std TempleOS $LK,"DCLighting",A="MN:DCLighting"$() color.
  I64 i;
  CDoc *doc=DocNew;
  if (header)
    DocPrint(doc,"%s",header);
  DocPrint(doc,"\nSingle-Sided means front and back different."
	"\nDouble-Sided means front and back same."
	"\n"
	"\nHalf-Range means 0to[0,7]"
	"\n[8,15]-8to[8,15]"
	"\nFull-Range means 0to[0,7]to[0,7]+8"
	"\n");
  DocPrint(doc,
	"\n$$LTPURPLE$$Single-Sided Full-Range Double-Sided Full-Range\n$$BLACK$$");
  for (i=0;i<COLORS_NUM/2;i++) {
    DocPrint(doc,"$$BG,%d$$$$MU,\"__%-19Z__\",LE=%d$$$$BG$$ ",i,i,"ST_COLORS",i);
    DocPrint(doc,"$$BG,%d$$$$MU,\"__%-19Z__\",LE=%d$$$$BG$$\n",i,i,"ST_COLORS",
	  ROPF_TWO_SIDED+i);
  }
  DocPrint(doc,
	"\n$$LTPURPLE$$Single-Sided Half-Range Double-Sided Half-Range\n$$BLACK$$");
  for (i=0;i<COLORS_NUM;i++) {
    DocPrint(doc,"$$BG,%d$$$$MU,\"__%-19Z__\",LE=%d$$$$BG$$ ",
	  i,i,"ST_COLORS",ROPF_HALF_RANGE_COLOR+i);
    DocPrint(doc,"$$BG,%d$$$$MU,\"__%-19Z__\",LE=%d$$$$BG$$\n",
	  i,i,"ST_COLORS",ROPF_TWO_SIDED+ROPF_HALF_RANGE_COLOR+i);
  }
  i=PopUpMenu(doc);
  DocDel(doc);
  return i;
}

