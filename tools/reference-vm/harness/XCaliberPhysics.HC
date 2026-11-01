//XCaliberPhysics.HC: INSTRUMENTED DRIVER, not a TempleOS program. Deterministic replay of
//::/Apps/X-Caliber (X-Caliber.HC, XCCtrls.HC via the CD's Load.HC, all unmodified) without its main
//loop, windows or real-time clock, so the same file gives comparable results on the original
//TempleOS (reference VM), the app's interpreter and its native translations.
//
//What differs from the real game (XCaliber() in X-Caliber.HC, ODEsUpdate in Adam/AMathODE.HC):
// * tS is replaced in the game's code by the harness clock xc_t (#define tS xc_t before the
//   include; TempleOS has no #undef, so tS and Fs stay redefined for the rest of this file).
// * Fs is replaced in the game's code by xc_fs, a zeroed CTask with pix_width=XC_W and
//   pix_height=XC_H (the game reads only those two fields through Fs, in InitLevel/PlaceShip);
//   ode->win_task is xc_fs too (MyDerivative/SolarFlares read the same two fields).
// * The ODE is not put on the task's ODE list (the window manager never integrates it). Each frame
//   it is integrated to t+1/30 by XcIntegrate, ODEsUpdate's own loop (ODEState2Internal, the
//   RK5 Cash-Karp steps with state_scale, the interpolation, ODEInternal2State, the convenience
//   ODECallDerivative) without the real-time timeout and with a FIXED tolerance XC_TOL (the game
//   lets the window manager tune it between min_tolerance 1e-9 and max_tolerance 0.01 by CPU load).
// * Per frame, as in XCaliber()'s loop: scripted input, AI, SolarFlares, ExpireShots, ExpireSplats,
//   ExpireMissiles, CheckDamage, then the ODE update (the game's Refresh), then the level-complete
//   check. Game logic at frame k sees xc_t=XC_T0+k/30; the update of frame k runs at
//   xc_t=XC_T0+(k+1)/30 and integrates ode->t from k/30 to (k+1)/30.
// * The level-1 "Face away from Sun" OneTimePopUp is pre-acknowledged (msg_flags bit set) and the
//   level message is dismissed at once (show_level_msg=FALSE, ODEPause(ode,OFF)).
// * Input script: thrust (CURSOR-UP down) on frame 10, released on frame 40; fire (SPACE) on frame
//   30; left missile (CTRL-CURSOR-LEFT) on frame 60 -- the same assignments XCaliber() makes.
// * Seed(XC_SEED) in this task before Init. If XC_HARNESS_RNG is defined (XCaliberLcg.HC), RandU16
//   and Rand in the game's code are replaced by XcRandU16/XcRand: TempleOS's own LCG
//   (Kernel/KMathB.HC) written out in this file with its own state, so engines whose Rand differs
//   can still be compared on the physics.
//Output (HPrint): STATE <frame> lines with every mass, ship summaries and FNV-1a 64 hashes.

#define XC_SEED		12345
#define XC_TOL		1e-6
#define XC_FRAMES	120
#define XC_FPS		30
#define XC_T0		1000.0
#define XC_W		640
#define XC_H		472

F64 xc_t=XC_T0;
I64 xc_steps=0,xc_lcg=XC_SEED,xc_hrng=0;
CTask *xc_fs;
xc_fs=CAlloc(sizeof(CTask));
xc_fs->pix_width=XC_W;
xc_fs->pix_height=XC_H;

U16 XcRandU16()
{//Kernel/KMathB.HC RandU16 with TASKf_NONTIMER_RAND, on xc_lcg.
  I64 res=xc_lcg;
  res=6364136223846793005*res^(res&0xFFFFFFFF0000)>>16+1442695040888963407;
  xc_lcg=res;
  return res&0xFFFF;
}

F64 XcRand()
{//Kernel/KMathB.HC Rand with TASKf_NONTIMER_RAND, on xc_lcg.
  I64 res=xc_lcg;
  res=6364136223846793005*res^(res&0xFFFFFFFF0000)>>16+1442695040888963407;
  xc_lcg=res;
  return (res&0x3FFFFFFFFFFFFFFF)/ToF64(0x4000000000000000);
}

I64 XcB(F64 d)
{//Raw bits of an F64.
  I64 b;
  MemCpy(&b,&d,8);
  return b;
}

//For the record only (the replay uses XC_W x XC_H): the window X-Caliber gets on this engine.
WinBorder;
WinMax;
Refresh;
HPrint("PIX real pix_width=%d pix_height=%d\n",Fs->pix_width,Fs->pix_height);

#ifdef XC_HARNESS_RNG
xc_hrng=1;
#define RandU16 XcRandU16
#define Rand XcRand
#endif
#define tS xc_t
#define Fs xc_fs
#include "::/Apps/X-Caliber/Load.HC"

U0 XcIntegrate(CMathODE *o,F64 t_desired)
{//ODEsUpdate's integration of one ODE, without the timeout (Adam/AMathODE.HC).
  I64 i;
  F64 t_initial=o->t,interpolation;
  ODEState2Internal(o);
  MemCpy(o->initial_state,o->state_internal,o->n_internal*sizeof(F64));
  while (o->t<t_desired) {
    o->h_max=t_desired-o->t;
    ODECallDerivative(o,o->t,o->state_internal,o->DstateDt);
    for (i=0;i<o->n_internal;i++)
      o->state_scale[i]=Abs(o->state_internal[i])+
	    Abs(o->DstateDt[i]*o->h)+o->tolerance_internal;
    ODERK5OneStep(o);
    xc_steps++;
  }
  if (o->t!=t_desired) {
    if (interpolation=o->t-t_initial) {
      interpolation=(t_desired-t_initial)/interpolation;
      if (interpolation!=1.0)
	for (i=0;i<o->n_internal;i++)
	  o->state_internal[i]=(o->state_internal[i]-
		o->initial_state[i])*interpolation+o->initial_state[i];
    }
    o->t=t_desired;
  }
  ODEInternal2State(o);
  ODECallDerivative(o,o->t,o->state_internal,o->DstateDt);
}

U0 XcState(I64 frame)
{
  I64 n=0,ships=0,shots=0,i,inactive;
  U64 h=0xCBF29CE484222325,hs;
  MyMass *m;
  Ship *sp;
  Shot *st;
  Missile *mi;
  HPrint("STATE %d t=%016X ode_t=%016X ode_h=%016X n_internal=%d steps=%d score=%d level=%d "
	"remaining=%d game_over=%d human=%d\n",frame,XcB(xc_t),XcB(ode->t),XcB(ode->h),ode->n_internal,
	xc_steps,score,level,remaining,game_over,human!=NULL);
  m=ode->next_mass;
  while (m!=&ode->next_mass) {
    HPrint("MASS %d %d type=%d x=%016X y=%016X DxDt=%016X DyDt=%016X temp=%016X\n",frame,n,
	  m->type,XcB(m->x),XcB(m->y),XcB(m->DxDt),XcB(m->DyDt),XcB(m->temperature));
    h=Fnv64(&m->x,8,h);
    h=Fnv64(&m->y,8,h);
    h=Fnv64(&m->DxDt,8,h);
    h=Fnv64(&m->DyDt,8,h);
    n++;
    m=m->next;
  }
  sp=ship_head.next;
  while (sp!=&ship_head) {
    inactive=0;
    for (i=0;i<sp->springs;i++)
      if (sp->s[i].flags&SSF_INACTIVE)
	inactive|=1<<i;
    HPrint("SHIP %d %d type=%d masses=%d exploding=%d inactive_springs=%X reload=%016X\n",
	  frame,ships,sp->type,sp->masses,sp->exploding,inactive,XcB(sp->reload_timeout));
    ships++;
    sp=sp->next;
  }
  st=shot_head.next;
  while (st!=&shot_head) {
    shots++;
    st=st->next;
  }
  mi=missile_head.next;
  i=0;
  while (mi!=&missile_head) {
    HPrint("MISSILE %d %d label=%s active=%d launched=%d exploding=%d target=%d\n",frame,i,
	  mi->label,mi->active,mi->launched,mi->exploding,mi->target!=NULL);
    i++;
    mi=mi->next;
  }
  hs=Fnv64(&score,8,h);
  hs=Fnv64(&ships,8,hs);
  HPrint("HASH %d masses=%d ships=%d shots=%d mass_hash=%016X state_hash=%016X\n",
	frame,n,ships,shots,h,hs);
}

U0 XcMain()
{
  I64 frame;
  HPrint("XC-START seed=%d tol=%016X frames=%d harness_rng=%d\n",XC_SEED,XcB(XC_TOL),XC_FRAMES,
	xc_hrng);
  Seed(XC_SEED);
  xc_lcg=XC_SEED;
  LBts(&msg_flags,XMSGF_SOLAR_STORM);
  ode=ODENew(0,0.01,ODEF_HAS_MASSES);
  ode->derive=&MyDerivative;
  ode->min_tolerance=1e-9;
  ode->drag_v3=0.00001;
  ode->win_task=xc_fs;
  Init;
  ode->min_tolerance=ode->max_tolerance=ode->tolerance_internal=XC_TOL;
  ODEPause(ode,OFF);
  show_level_msg=FALSE;
  XcState(0);
  for (frame=0;frame<XC_FRAMES;frame++) {
    xc_t=XC_T0+ToF64(frame)/XC_FPS;
    HProgress(frame);
    if (frame==10) {	//CURSOR-UP down
      human_t_right=THRUST_MAX;
      human_t_left =THRUST_MAX;
    }
    if (frame==30)	//SPACE (level<4)
      HumanFireGunBegin;
    if (frame==40) {	//CURSOR-UP up
      human_t_right=0;
      human_t_left =0;
    }
    if (frame==60)	//CTRL-CURSOR-LEFT
      HumanFireMissileBegin(1);
    AI;
    SolarFlares;
    ExpireShots;
    ExpireSplats;
    ExpireMissiles;
    CheckDamage;
    xc_t=XC_T0+ToF64(frame+1)/XC_FPS;
    XcIntegrate(ode,ToF64(frame+1)/XC_FPS);
    if (!game_over && !remaining) {
      level++;
      ShipDel(human);
      human=NULL;
      InitLevel;
      ODEPause(ode,OFF);
      show_level_msg=FALSE;
      HPrint("LEVEL-UP frame=%d level=%d\n",frame+1,level);
    }
    if (!((frame+1)%30))
      XcState(frame+1);
  }
  HPrint("XC-END steps=%d\n",xc_steps);
}

XcMain;
