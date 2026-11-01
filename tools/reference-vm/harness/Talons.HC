//Talons.HC: INSTRUMENTED DRIVER, not a TempleOS program. Measures ::/Demo/Games/Talons.HC.
//It #includes TalonsNoRun.HC = the CD's Talons.HC with exactly one change: its last text line
//"Talons;" (the auto-run call, 8 bytes "Talons;\n" before the DolDoc binary sprites) is removed, so
//that the include compiles everything and runs only Talons.HC's top-level RegDft/RegExe statements.
//fixtures.py makes the copy from the original and records both sha256 values.
//
//Prints (HPrint):
//  MEM <label> ...            the OS's memory accounting (VmIO.HC HMemSnap; AppIO.HC on the app)
//  SIZES ...                  sizeof of Talons' big globals
//  HASH <name> <fnv> <16 block hashes>   FNV-1a 64 of the raw bytes, whole array and 16 row blocks
//  SAMPLE <name> ...          a few raw values
//  PANELS ...                 panels/objects after Init (InitMap's MPDoPanels on every CPU)
//Terrain: Seed(TAL_SEED) in this task, then Talons' own InitElevations and CalcNormals. A second
//normals pass runs on a synthetic elevation field filled by this driver's own integer LCG (the same
//on any engine), so CalcNormals' F64 arithmetic can be compared even where Rand differs.

#define TAL_SEED	12345
I64 tal_pts[5][2]={{0,0},{512,512},{100,900},{1022,1022},{777,333}};

HMemSnap("before-include");
HDataCd;;
#include "TalonsNoRun.HC"
HMemSnap("after-include");

U0 TalHash(U8 *name,U8 *base,I64 size)
{
  I64 i,blk=size/16;
  HPrint("HASH %s %016X",name,Fnv64(base,size));
  for (i=0;i<16;i++)
    HPrint(" %016X",Fnv64(base+i*blk,blk));
  HPrint("\n");
}

U0 TalSampleNormals(U8 *name)
{
  I64 k,i,j,b[3];

  HPrint("SAMPLE %s",name);
  for (k=0;k<5;k++) {
    j=tal_pts[k][0];
    i=tal_pts[k][1];
    MemCpy(b,&normals[j][i],24);
    HPrint(" [%d,%d]=%016X,%016X,%016X",j,i,b[0],b[1],b[2]);
  }
  HPrint("\n");
}

U0 TalSynth()
{
  I64 i,j,s=0x9E3779B97F4A7C15;
  for (j=0;j<MAP_HEIGHT;j++)
    for (i=0;i<MAP_WIDTH;i++) {
      s=s*6364136223846793005+1442695040888963407;
      elevations[j][i]=(s>>40)&0x3FFF;
    }
}

U0 TalMain()
{
  I64 i,j,np=0,no=0,nwater=0;
  Panel *tmpp;
  Obj *tmpo;
  HPrint("SIZES elevations=%d normals=%d panels=%d CD3=%d mp_cnt=%d\n",
	sizeof(elevations),sizeof(normals),sizeof(panels),sizeof(CD3),mp_cnt);

  Seed(TAL_SEED);
  InitElevations;
  TalHash("elevations",elevations,sizeof(elevations));
  HPrint("SAMPLE elevations [0,0]=%d [512,512]=%d [100,900]=%d [1023,1023]=%d [777,333]=%d\n",
	elevations[0][0],elevations[512][512],elevations[100][900],
	elevations[1023][1023],elevations[777][333]);
  for (j=0;j<MAP_HEIGHT;j++)
    for (i=0;i<MAP_WIDTH;i++)
      if (elevations[j][i]==WATER_ELEVATION*MAP_SCALE)
	nwater++;
  HPrint("WATER cells=%d\n",nwater);
  CalcNormals;
  TalHash("normals",normals,sizeof(normals));
  TalSampleNormals("normals");
  HMemSnap("after-terrain");

  TalSynth;
  TalHash("synthetic_elevations",elevations,sizeof(elevations));
  CalcNormals;
  TalHash("synthetic_normals",normals,sizeof(normals));
  TalSampleNormals("synthetic_normals");

  Seed(TAL_SEED);
  PreInit;
  HMemSnap("after-PreInit");
  Init;	//InitMap (InitElevations, CalcNormals, MPDoPanels on every CPU), depth buffer, birds
  tmpp=panel_head;
  while (tmpp) {
    np++;
    tmpo=tmpp->next_obj;
    while (tmpo!=&tmpp->next_obj) {
      no++;
      tmpo=tmpo->next;
    }
    tmpp=tmpp->next;
  }
  HPrint("PANELS panels=%d objects=%d (objects use Rand in the spawned MPDoPanels tasks)\n",np,no);
  TalHash("elevations_after_Init",elevations,sizeof(elevations));
  HMemSnap("after-Init");
  CleanUp;
  PostCleanUp;
  Fs->task_end_cb=NULL;
  HMemSnap("after-CleanUp");
  HPrint("TALONS-END\n");
}

TalMain;
