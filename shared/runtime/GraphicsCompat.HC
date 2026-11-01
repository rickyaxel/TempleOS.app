// Compatibility primitives derived from TempleOS V5.03 (Terry A. Davis, public domain).

CGridGlbls ms_grid;

U0 GridInit()
{//Init mouse grid struct. See $LK,"::/Demo/Graphics/Grid.HC"$.
  ms_grid.x=ms_grid.y=ms_grid.z=8;
  ms_grid.x_offset=ms_grid.y_offset=ms_grid.z_offset=0;
  ms_grid.x_speed =ms_grid.y_speed =ms_grid.z_speed =1;
  ms_grid.show=ms_grid.snap=ms_grid.coord=FALSE;
}



GridInit;

U32 char_bmp_safe_dollar[16]=
  {0x80000000,0xFFFFFFEF,0xFFFFFFFF,0x7FFFFFFF,
  0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,
  0,0,0,0,0,0,0,0};

public CBGR48 gr_palette_gray[COLORS_NUM]={
0x000000000000,0x111111111111,0x222222222222,0x333333333333,
0x444444444444,0x555555555555,0x666666666666,0x777777777777,
0x888888888888,0x999999999999,0xAAAAAAAAAAAA,0xBBBBBBBBBBBB,
0xCCCCCCCCCCCC,0xDDDDDDDDDDDD,0xEEEEEEEEEEEE,0xFFFFFFFFFFFF};



U8 *Color2Str(U8 *buf,CColorROPU32 c)
{//$LK,"CColorROPU32",A="MN:CColorROPU32"$ with flags to $LK,"DCLighting",A="MN:DCLighting"$ str.
  *buf=0;
  if (c.c0.rop&ROPBF_TWO_SIDED)
    CatPrint(buf,"TWO|");
  if (c.c0.rop&ROPBF_HALF_RANGE_COLOR)
    CatPrint(buf,"HALF|");
  if (0<=c.c0.color<16)
    CatPrint(buf,DefineSub(c.c0.color,"ST_COLORS"));
  else if (c.c0.color==TRANSPARENT)
    CatPrint(buf,"TRANSPARENT");
  else
    CatPrint(buf,"INVALID");
  if (c&ROPF_DITHER) {
    CatPrint(buf,"/");
    if (c.c1.rop&ROPBF_TWO_SIDED)
      CatPrint(buf,"TWO|");
    if (c.c1.rop&ROPBF_HALF_RANGE_COLOR)
      CatPrint(buf,"HALF|");
    if (0<=c.c1.color<16)
      CatPrint(buf,DefineSub(c.c1.color,"ST_COLORS"));
    else if (c.c1.color==TRANSPARENT)
      CatPrint(buf,"TRANSPARENT");
    else
      CatPrint(buf,"INVALID");
  }
  return buf;
}

#help_index "Graphics"

U0 GrInit1()
{
  DefineLstLoad("ST_SPRITE_ELEM_TYPES",
	"End\0Color\0Dither Color\0"
	"Thick\0Planar Symmetry\0Transform On\0Transform Off\0Shift\0"
	"Point\0PolyPoint\0Line\0PolyLine\0Rect\0Rotated Rect\0"
	"Circle\0Ellipse\0Polygon\0BSpline2\0BSpline2 Closed\0"
	"BSpline3\0BSpline3 Closed\0"
	"Flood Fill\0Flood Fill Not Color\0BitMap\0Mesh\0Shiftable Mesh\0"
	"Arrow\0Text\0Text Box\0Text Diamond\0");
  DefineLstLoad("ST_SPRITE_ELEM_CODES",
	"End\0Color\0Color\0"
	"Thick\0PlanarSymmetry\0Transform\0Transform\0Shift\0"
	"Pt\0PolyPt\0Line\0PolyLine\0Rect\0Rect\0"
	"Circle\0Ellipse\0Polygon\0BSpline2\0BSpline2\0BSpline3\0BSpline3\0"
	"FloodFill\0FloodFill\0BitMap\0Mesh\0Mesh\0"
	"Arrow\0Text\0TextBox\0TextDiamond\0");
}
GrInit1;


public U8 *SpriteElem2Summary(CSprite *tmpg)
{//Study $LK,"::/Demo/Graphics/SpriteText.HC"$.
  U8 buf[STR_LEN],buf2[STR_LEN];
  I32 *ptr;
  StrPrint(buf,"%Z",tmpg->type&SPG_TYPE_MASK,"ST_SPRITE_ELEM_TYPES");
  switch (tmpg->type&SPG_TYPE_MASK) {
    case SPT_COLOR:
      CatPrint(buf,"%s",Color2Str(buf2,tmpg->c.color));
      break;
    case SPT_DITHER_COLOR:
      CatPrint(buf,"%s",Color2Str(buf2,ROPF_DITHER|tmpg->d.dither_color.u8[0]|
	    tmpg->d.dither_color.u8[1]<<COLORROP_BITS));
      break;
    case SPT_PT:
    case SPT_FLOOD_FILL:
    case SPT_FLOOD_FILL_NOT:
    case SPT_SHIFT:
      CatPrint(buf,"(%d,%d)",tmpg->p.x1,tmpg->p.y1);
      break;
    case SPT_LINE:
    case SPT_ARROW:
    case SPT_PLANAR_SYMMETRY:
    case SPT_RECT:
    case SPT_ROTATED_RECT:
      CatPrint(buf,"(%d,%d),(%d,%d)",tmpg->pp.x1,tmpg->pp.y1,
	    tmpg->pp.x2,tmpg->pp.y2);
      break;
    case SPT_CIRCLE:
      CatPrint(buf,"(%d,%d):%dR",tmpg->pr.x1,tmpg->pr.y1,tmpg->pr.radius);
      break;
    case SPT_THICK:
      CatPrint(buf,"%d",tmpg->t.thick);
      break;
    case SPT_TEXT:
    case SPT_TEXT_BOX:
    case SPT_TEXT_DIAMOND:
      CatPrint(buf,"%d,%d:%-16t$$Q",tmpg->ps.x1,tmpg->ps.y1,tmpg->ps.st);
      break;
    case SPT_POLYLINE:
    case SPT_POLYPT:
      ptr=&tmpg->npu.x;
      CatPrint(buf,"%d(%d,%d)",tmpg->npu.num,ptr[0],ptr[1]);
      break;
    case SPT_ELLIPSE:
    case SPT_POLYGON:
    case SPT_BITMAP:
      CatPrint(buf,"(%d,%d):%dW,%dH",tmpg->pwhu.x1,tmpg->pwhu.y1,
	    tmpg->pwhu.width,tmpg->pwhu.height);
      break;
    case SPT_BSPLINE2:
    case SPT_BSPLINE3:
    case SPT_BSPLINE2_CLOSED:
    case SPT_BSPLINE3_CLOSED:
      CatPrint(buf,"%d",tmpg->nu.num);
      break;
    case SPT_MESH:
      CatPrint(buf,"%dV,%dT",tmpg->mu.vertex_cnt,tmpg->mu.tri_cnt);
      break;
    case SPT_SHIFTABLE_MESH:
      CatPrint(buf,"%dV,%dT",tmpg->pmu.vertex_cnt,tmpg->pmu.tri_cnt);
      break;
  }
  return StrNew(buf);
}


#help_index "Graphics/Sprite;Sprites"

U0 SpriteElem2Code(CDoc *doc,CSprite *tmpg)
{
  U8 buf1[STR_LEN],buf2[STR_LEN];
  I32 *ptr;
  I64 i,j,k,col,width_internal;
  CD3I32 *p;
  CMeshTri *tri;
  if (!doc) doc=DocPut;
  DocPrint(doc,"%Z",tmpg->type&SPG_TYPE_MASK,"ST_SPRITE_ELEM_CODES");
  switch (tmpg->type&SPG_TYPE_MASK) {
    case SPT_COLOR:
      DocPrint(doc,"{%s}",
	    Color2Str(buf1,tmpg->c.color));
      break;
    case SPT_DITHER_COLOR:
      DocPrint(doc,"{%s}",
	    Color2Str(buf2,ROPF_DITHER|tmpg->d.dither_color.u8[0]|
	    tmpg->d.dither_color.u8[1]<<COLORROP_BITS));
      break;
    case SPT_TRANSFORM_ON:
      DocPrint(doc,"{ON}");
      break;
    case SPT_TRANSFORM_OFF:
      DocPrint(doc,"{OFF}");
      break;
    case SPT_LINE:
    case SPT_ARROW:
    case SPT_PLANAR_SYMMETRY:
      DocPrint(doc,"{(%d,%d),(%d,%d)}",tmpg->pp.x1,tmpg->pp.y1,
	    tmpg->pp.x2,tmpg->pp.y2);
      break;
    case SPT_RECT:
      DocPrint(doc,"{(%d,%d):(%d,%d)}",tmpg->pp.x1,tmpg->pp.y1,
	    tmpg->pp.x2-tmpg->pp.x1,tmpg->pp.y2-tmpg->pp.y1);
      break;
    case SPT_ROTATED_RECT:
      DocPrint(doc,"{(%d,%d):(%d,%d),%0.4f}",tmpg->ppa.x1,tmpg->ppa.y1,
	    tmpg->ppa.x2-tmpg->ppa.x1,tmpg->ppa.y2-tmpg->ppa.y1,
	    180/ã*Wrap(tmpg->ppa.angle));
      break;
    case SPT_PT:
    case SPT_FLOOD_FILL:
    case SPT_SHIFT:
      DocPrint(doc,"{(%d,%d)}",tmpg->p.x1,tmpg->p.y1);
      break;
    case SPT_FLOOD_FILL_NOT:
      DocPrint(doc,"{(%d,%d),TRUE}",tmpg->p.x1,tmpg->p.y1);
      break;
    case SPT_CIRCLE:
      DocPrint(doc,"{(%d,%d):%d}",tmpg->pr.x1,tmpg->pr.y1,tmpg->pr.radius);
      break;
    case SPT_THICK:
      DocPrint(doc,"{%d}",tmpg->t.thick);
      break;
    case SPT_ELLIPSE:
      DocPrint(doc,"{(%d,%d):(%d,%d),%0.4f}",tmpg->pwha.x1,tmpg->pwha.y1,
	    tmpg->pwha.width,tmpg->pwha.height,180/ã*Wrap(tmpg->pwha.angle));
      break;
    case SPT_POLYGON:
      DocPrint(doc,"{%d,(%d,%d):(%d,%d),%0.4f}",tmpg->pwhas.sides,
	    tmpg->pwhas.x1,tmpg->pwhas.y1,
	    tmpg->pwhas.width,tmpg->pwhas.height,
	    180/ã*Wrap(tmpg->pwhas.angle));
      break;
    case SPT_TEXT:
    case SPT_TEXT_BOX:
    case SPT_TEXT_DIAMOND:
      DocPrint(doc,"{(%d,%d),\"%Q\"}",tmpg->ps.x1,tmpg->ps.y1,tmpg->ps.st);
      break;
    case SPT_POLYLINE:
      ptr=&tmpg->nu.u;
      DocPrint(doc,"{");
      for (i=0;i<tmpg->nu.num;i++,ptr+=2) {
	DocPrint(doc,"(%d,%d)",ptr[0],ptr[1]);
	if (i+1<tmpg->nu.num) DocPrint(doc,",");
	if (i&3==3 && i+1<tmpg->nu.num)
	  DocPrint(doc,"\n");
      }
      DocPrint(doc,"}");
      break;
    case SPT_BSPLINE2:
    case SPT_BSPLINE3:
    case SPT_BSPLINE2_CLOSED:
    case SPT_BSPLINE3_CLOSED:
      ptr=&tmpg->nu.u;
      DocPrint(doc,"{");
      for (i=0;i<tmpg->nu.num;i++,ptr+=3) {
	DocPrint(doc,"(%d,%d,%d)",ptr[0],ptr[1],ptr[2]);
	if (i+1<tmpg->nu.num) DocPrint(doc,",");
	if (i&3==3 && i+1<tmpg->nu.num)
	  DocPrint(doc,"\n");
      }
      if (tmpg->type&SPG_TYPE_MASK==SPT_BSPLINE2||
	    tmpg->type&SPG_TYPE_MASK==SPT_BSPLINE3)
	DocPrint(doc,",FALSE}");
      else
	DocPrint(doc,",TRUE}");
      break;
    case SPT_POLYPT:
      DocPrint(doc,"{(%d,%d),",tmpg->npu.x,tmpg->npu.y);
      ptr=&tmpg->npu.u;
      col=16;
      for (i=0;i<tmpg->npu.num;i++) {
	DocPrint(doc,"%d",BFieldExtU32(ptr,i*3,3));
	if (++col>=64 && i+1<tmpg->npu.num) {
	  DocPrint(doc,"\n");
	  col=0;
	}
      }
      DocPrint(doc,"}");
      break;
    case SPT_BITMAP:
      DocPrint(doc,"{(%d,%d):(%d,%d),\n",tmpg->pwhu.x1,tmpg->pwhu.y1,
	    tmpg->pwhu.width,tmpg->pwhu.height);
      width_internal=(tmpg->pwhu.width+7)&~7;
      if (width_internal<80)
	k=width_internal;
      else
	k=64;
      ptr=&tmpg->pwhu.u;
      col=0;
      for (j=0;j<tmpg->pwhu.height;j++)
	for (i=0;i<width_internal;i++,ptr(U8 *)++) {
	  if (i>=tmpg->pwhu.width)
	    DocPrint(doc,"_");
	  else if (*ptr(U8 *)<16)
	    DocPrint(doc,"%X",*ptr(U8 *));
	  else
	    DocPrint(doc,"%c",CH_SHIFT_SPACE);
	  if (++col>=k && (i+1<width_internal||j+1<tmpg->pwhu.height)) {
	    DocPrint(doc,"\n");
	    col=0;
	  }
	}
      DocPrint(doc,"}");
      break;
    case SPT_MESH:
      DocPrint(doc,"{FALSE,");
      p=&tmpg->mu.u;
      col=0;
      for (i=0;i<tmpg->mu.vertex_cnt;i++,p++) {
	DocPrint(doc,"(%d,%d,%d)",p->x,p->y,p->z);
	if (i+1<tmpg->mu.vertex_cnt) DocPrint(doc,",");
	if (++col==4) {
	  DocPrint(doc,"\t//%d\n",i);
	  col=0;
	}
      }
      DocPrint(doc,":");
      tri=p;
      for (i=0;i<tmpg->mu.tri_cnt;i++,tri++) {
	DocPrint(doc,"(%s,%d,%d,%d)",Color2Str(buf1,tri->color),
	      tri->nums[0],tri->nums[1],tri->nums[2]);
	if (i+1<tmpg->mu.tri_cnt) DocPrint(doc,",");
	if (++col>=3 && i+1<tmpg->mu.tri_cnt) {
	  DocPrint(doc,"\n");
	  col=0;
	}
      }
      DocPrint(doc,"}");
      break;
    case SPT_SHIFTABLE_MESH:
      DocPrint(doc,"{TRUE,(%d,%d,%d):",tmpg->pmu.x,tmpg->pmu.y,tmpg->pmu.z);
      p=&tmpg->pmu.u;
      col=1;
      for (i=0;i<tmpg->pmu.vertex_cnt;i++,p++) {
	DocPrint(doc,"(%d,%d,%d)",p->x,p->y,p->z);
	if (i+1<tmpg->pmu.vertex_cnt) DocPrint(doc,",");
	if (++col==4) {
	  DocPrint(doc,"\t//%d\n",i);
	  col=0;
	}
      }
      DocPrint(doc,":");
      tri=p;
      for (i=0;i<tmpg->pmu.tri_cnt;i++,tri++) {
	DocPrint(doc,"(%s,%d,%d,%d)",Color2Str(buf1,tri->color),
	      tri->nums[0],tri->nums[1],tri->nums[2]);
	if (i+1<tmpg->pmu.tri_cnt) DocPrint(doc,",");
	if (++col>=3 && i+1<tmpg->pmu.tri_cnt) {
	  DocPrint(doc,"\n");
	  col=0;
	}
      }
      DocPrint(doc,"}");
      break;
  }
    DocPrint(doc,";\n");
}

public U0 Sprite2Code(CDoc *doc=NULL,U8 *elems)
{//Sprite to text.
  CSprite *tmpg=elems-offset(CSprite.start);
  while (tmpg->type&SPG_TYPE_MASK) {
    SpriteElem2Code(doc,tmpg);
    tmpg(U8 *)+=SpriteElemSize(tmpg);
  }
}

