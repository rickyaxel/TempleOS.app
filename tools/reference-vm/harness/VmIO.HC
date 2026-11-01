//VmIO.HC: stage 1 of the reference-VM harness channel (tools/reference-vm/templeos_harness.py).
//Development tool, never shipped. Loaded from QEMU fw_cfg by the short stage-0 loader that
//templeos_harness.py types at the TempleOS prompt (STAGE0 there); nothing on the ISO is changed.
//
//OUTPUT  QEMU isa-debugcon devices: port 0xE9 carries the structured harness stream (HPrint),
//        port 0xEA a raw copy of everything the harness task prints (compiler errors included),
//        taken from a hook in TempleOS's own StdOut chain (KeyDevAdd, Kernel/KeyDev.HC).
//        TempleOS runs every task in ring 0, so OutU8/RepOutU8 to these ports is allowed.
//INPUT   QEMU fw_cfg: selector port 0x510 (16-bit write), data port 0x511 (byte reads); the file
//        directory is item 0x19: a big-endian U32 count, then 64-byte entries
//        {U32 size BE, U16 select BE, U16 reserved, U8 name[56]}.
//
//Harness programs use only HPut/HPrint/HCapBegin/HCapEnd/HData/HProgress, which the app's
//interpreter gets from AppIO.HC instead, so the same harness file runs on both.

#define DBG_PORT	0xE9
#define CON_PORT	0xEA
#define FWCFG_SEL	0x510
#define FWCFG_DATA	0x511
#define FWCFG_DIR	0x19

I64 dbg_lock=0,hb_progress=0;
Bool dbg_bol=TRUE;	//port 0xE9 stream is at the start of a line (the heartbeat only writes there)
CTask *dbg_task=NULL;	//the harness task: only its output is mirrored (unless dbg_mirror_all)
Bool dbg_mirror_all=FALSE;
U8 *hcap_buf=NULL;	//capture of the harness task's printed output (HCapBegin/HCapEnd)
I64 hcap_len=0,hcap_size=0;

U0 DbgPutN(U8 *s,I64 n,I64 port=DBG_PORT)
{//Raw bytes to a debugcon port (spin lock: the heartbeat task writes from CPU 1).
//Not RepOutU8: in V5.03 it raises an Invalid Opcode fault (#UD, the debugger shows POP ES at its
//REP_OUTSB), observed in this VM on 2026-10-20. RepInU8 works and is used for fw_cfg.
  if (n<=0) return;
  while (LBts(&dbg_lock,0))
    Yield;
  if (port==DBG_PORT)
    dbg_bol=s[n-1]=='\n';
  while (n--)
    OutU8(port,*s++);
  LBtr(&dbg_lock,0);
}

U0 DbgPut(U8 *s)
{
  if (s) DbgPutN(s,StrLen(s));
}

U0 DbgPrint(U8 *fmt,...)
{//Formatted output to port 0xE9 (StrPrintJoin is what Print and StrPrint use).
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv);
  DbgPut(buf);
  Free(buf);
}

U0 HPut(U8 *s)
{
  DbgPut(s);
}

U0 HPrint(U8 *fmt,...)
{
  U8 *buf=StrPrintJoin(NULL,fmt,argc,argv);
  DbgPut(buf);
  Free(buf);
}

U0 HProgress(I64 n)
{
  hb_progress=n;
}

U0 HCapAdd(U8 *s,I64 n)
{
  U8 *b;
  if (hcap_len+n+1>hcap_size) {
    hcap_size=(hcap_len+n+1)*2;
    b=MAlloc(hcap_size,dbg_task);
    MemCpy(b,hcap_buf,hcap_len);
    Free(hcap_buf);
    hcap_buf=b;
  }
  MemCpy(hcap_buf+hcap_len,s,n);
  hcap_len+=n;
  hcap_buf[hcap_len]=0;
}

Bool DbgMirrorPutKey(I64 ch,I64 sc)
{
  U8 b;
  if ((Fs==dbg_task || dbg_mirror_all) && ch && !sc) {
    b=ch;
    DbgPutN(&b,1,CON_PORT);
    if (hcap_buf && Fs==dbg_task) HCapAdd(&b,1);
  }
  return FALSE;	//let the rest of the StdOut chain print it as usual
}

Bool DbgMirrorPutS(U8 *st)
{
  I64 n;
  if ((Fs==dbg_task || dbg_mirror_all) && st) {
    n=StrLen(st);
    DbgPutN(st,n,CON_PORT);
    if (hcap_buf && Fs==dbg_task) HCapAdd(st,n);
  }
  return FALSE;
}

U0 HMirrorAll(Bool val=ON)
{//Copy what every task prints to port 0xEA (e.g. a spawned task's exception report).
  dbg_mirror_all=val;
}

I64 HCcMark()
{//The task's compiler-context queue tail (Fs->last_cc), before an ExePrint.
  return Fs->last_cc;
}

I64 HCcRestore(I64 mark)
{//Unqueues CCmpCtrls an exception left behind (ExePutS skips QueRem when its catch does not
//take the exception); returns 1 if there were any.
  I64 res=0;
  while (Fs->last_cc!=mark) {
    QueRem(Fs->last_cc);
    res=1;
  }
  return res;
}

U0 HCapBegin()
{//Start collecting what this task prints.
  Free(hcap_buf);
  hcap_size=256;
  hcap_buf=MAlloc(hcap_size,dbg_task);
  hcap_len=0;
  *hcap_buf=0;
}

U8 *HCapEnd()
{//Stop collecting; returns the text (caller frees).
  U8 *res=hcap_buf;
  hcap_buf=NULL;
  return res;
}

I64 FwCfgBE(I64 n)
{
  I64 r=0;
  while (n--)
    r=r<<8|InU8(FWCFG_DATA);
  return r;
}

I64 FwCfgFind(U8 *name,I64 *_size=NULL)
{//fw_cfg selector of a named file, or -1.
  I64 n,size,sel;
  U8 e[56];
  OutU16(FWCFG_SEL,FWCFG_DIR);
  n=FwCfgBE(4);
  while (n--) {
    size=FwCfgBE(4);
    sel=FwCfgBE(2);
    FwCfgBE(2);
    RepInU8(e,56,FWCFG_DATA);
    if (!StrCmp(e,name)) {
      if (_size) *_size=size;
      return sel;
    }
  }
  return -1;
}

U8 *FwCfgRead(U8 *name,I64 *_size=NULL)
{//Whole fw_cfg file in a MAlloc'd buffer with a terminating 0, or NULL.
  I64 size,sel=FwCfgFind(name,&size);
  U8 *b;
  if (sel<0) return NULL;
  b=MAlloc(size+1);
  OutU16(FWCFG_SEL,sel);
  RepInU8(b,size,FWCFG_DATA);
  b[size]=0;
  if (_size) *_size=size;
  return b;
}

U8 *HData(U8 *name,I64 *_size=NULL)
{//A data file handed to the harness (run-harness --data NAME=PATH).
  U8 buf[64];
  StrPrint(buf,"opt/templeos/d/%s",name);
  return FwCfgRead(buf,_size);
}

U64 Fnv64(U8 *b,I64 n,U64 h=0xCBF29CE484222325)
{//FNV-1a 64.
  while (n-->0) {
    h^=*b++;
    h*=0x100000001B3;
  }
  return h;
}

U0 HDataToRamDisk()
{//Copies every fw_cfg file opt/templeos/d/NAME to B:/HData/NAME (the live CD's RAM drive), so that a
//harness can #include a data file (a DolDoc file with binary sprites needs a real file for #include).
  I64 i,n,cnt=0,size;
  U8 names[32][56],path[96],*b;
  OutU16(FWCFG_SEL,FWCFG_DIR);
  n=FwCfgBE(4);
  while (n--) {
    FwCfgBE(8);
    RepInU8(names[cnt],56,FWCFG_DATA);
    if (!StrNCmp(names[cnt],"opt/templeos/d/",15) && cnt<32)
      cnt++;
  }
  if (cnt)
    DirMk("B:/HData");
  for (i=0;i<cnt;i++) {
    b=FwCfgRead(names[i],&size);
    StrPrint(path,"B:/HData/%s",names[i]+15);
    FileWrite(path,b,size);
    DbgPrint("DATA %s size=%d fnv=%016X\n",path,size,Fnv64(b,size));
    Free(b);
  }
}

U0 HDataCd()
{//Current directory = where the data files are (VM: the RAM drive copy).
  Cd("B:/HData");
}

U0 HMemSnap(U8 *label)
{//TempleOS's own memory accounting (Kernel/Mem, Adam/AMem.HC TaskMemUsed/TaskMemAlloced).
  I64 du=0,da=0;
  if (sys_data_bp) {
    du=sys_data_bp->used_u8s;
    da=sys_data_bp->alloced_u8s;
  }
  HPrint("MEM %s sys_code_bp.used=%d sys_code_bp.alloced=%d sys_data_bp=%d sys_data_bp.used=%d "
	"sys_data_bp.alloced=%d code_heap.used=%d code_heap.alloced=%d data_heap.used=%d "
	"data_heap.alloced=%d task_used=%d task_alloced=%d mem_heap_limit=%d\n",label,
	sys_code_bp->used_u8s,sys_code_bp->alloced_u8s,sys_data_bp!=NULL,du,da,
	Fs->code_heap->used_u8s,Fs->code_heap->alloced_u8s,Fs->data_heap->used_u8s,
	Fs->data_heap->alloced_u8s,TaskMemUsed(Fs),TaskMemAlloced(Fs),mem_heap_limit);
}

U0 HHeartbeat(I64)
{//Runs on CPU 1: shows the host that the guest is alive and whether the debugger is up.
  I64 i;
  U8 buf[128],*p;
  while (TRUE) {
    Sleep(1000);
    StrPrint(buf,"HB %d %d %d\n",cnts.jiffies,hb_progress,IsDbgMode);
    for (i=0;i<5000;i++) {//only between lines: a harness line may be printed in pieces
      while (LBts(&dbg_lock,0))
	Yield;
      if (dbg_bol) {
	p=buf;
	while (*p)
	  OutU8(DBG_PORT,*p++);
	LBtr(&dbg_lock,0);
	break;
      }
      LBtr(&dbg_lock,0);
      Sleep(1);
    }
  }
}

U0 HarnessRunAll()
{
  I64 i,size,res;
  U8 name[64],*buf;
  dbg_task=Fs;
  KeyDevAdd(&DbgMirrorPutKey,&DbgMirrorPutS,0x10000000);
  if (mp_cnt>1)
    Spawn(&HHeartbeat,NULL,"HB",1);
  DbgPrint("BOOT-OK mp_cnt=%d sys_code_bp.alloced=%d\n",mp_cnt,sys_code_bp->alloced_u8s);
  HDataToRamDisk;
  for (i=0;TRUE;i++) {
    StrPrint(name,"opt/templeos/h%d",i);
    if (!(buf=FwCfgRead(name,&size)))
      break;
    DbgPrint("LOADER begin %s size=%d fnv=%016X\n",name,size,Fnv64(buf,size));
    Fs->except_ch=0;
    res=0;
    try {
      res=ExePutS(buf,name);
    } catch {
      DbgPrint("LOADER except %s ch=%c\n",name,Fs->except_ch);
      Fs->catch_except=TRUE;
    }
    if (Fs->except_ch=='Compiler')
      DbgPrint("LOADER compile-error %s\n",name);
    DbgPrint("LOADER end %s res=%016X\n",name,res);
    Free(buf);
  }
  DbgPrint("HARNESS-DONE\n");
}

HarnessRunAll;
