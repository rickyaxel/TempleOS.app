//Rng.HC: INSTRUMENTED DRIVER, not a TempleOS program. Dumps TempleOS's own random number
//sequences (Kernel/KMathB.HC: RandU64, RandU32, RandU16, RandI16, Rand) after Seed(n) in the
//running task. Output through HPrint (VmIO.HC on the reference VM, AppIO.HC on the app).
//Each line: RNG <seed hex> <function> <64 values>; RandI16 is printed sign-extended as I64 hex,
//Rand as the raw bits of the F64. Every function starts from a fresh Seed(seed).

#define RNG_N	64

U0 RngDump(I64 seed)
{
  I64 i,v,bits,ret;
  F64 d;
  ret=Seed(seed);
  HPrint("SEED %016X ret=%016X rand_seed=%016X nontimer=%d\n",seed,ret,
	Fs->rand_seed,Bt(&Fs->task_flags,TASKf_NONTIMER_RAND));

  Seed(seed);
  HPrint("RNG %016X RandU64",seed);
  for (i=0;i<RNG_N;i++) {
    v=RandU64;
    HPrint(" %016X",v);
  }
  HPrint("\n");

  Seed(seed);
  HPrint("RNG %016X RandU32",seed);
  for (i=0;i<RNG_N;i++) {
    v=RandU32;
    HPrint(" %016X",v);
  }
  HPrint("\n");

  Seed(seed);
  HPrint("RNG %016X RandU16",seed);
  for (i=0;i<RNG_N;i++) {
    v=RandU16;
    HPrint(" %016X",v);
  }
  HPrint("\n");

  Seed(seed);
  HPrint("RNG %016X RandI16",seed);
  for (i=0;i<RNG_N;i++) {
    v=RandI16;
    HPrint(" %016X",v);
  }
  HPrint("\n");

  Seed(seed);
  HPrint("RNG %016X Rand",seed);
  for (i=0;i<RNG_N;i++) {
    d=Rand;
    MemCpy(&bits,&d,8);
    HPrint(" %016X",bits);
  }
  HPrint("\n");

  Seed(seed);
  HPrint("RNG %016X state_after_RandU64",seed);
  for (i=0;i<4;i++) {
    RandU64;
    HPrint(" %016X",Fs->rand_seed);
  }
  HPrint("\n");
}

U0 RngMain()
{
  I64 i,v;
  HPrint("TASK-START rand_seed=%016X nontimer=%d\n",
	Fs->rand_seed,Bt(&Fs->task_flags,TASKf_NONTIMER_RAND));
  HPrint("UNSEEDED RandU64");	//before any Seed: TempleOS mixes in the TSC (not reproducible)
  for (i=0;i<4;i++) {
    v=RandU64;
    HPrint(" %016X",v);
  }
  HPrint("\n");
  RngDump(12345);
  RngDump(1);
  RngDump(-1);
  RngDump(0x0123456789ABCDEF);
  RngDump(0x8000000000000000);
  HPrint("RNG-END\n");
}

RngMain;
