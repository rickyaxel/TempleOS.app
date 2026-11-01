// Instrumented probe, not an original program. Calls unmodified V5.03 DCLoad/DCSave/ExpandBuf.
// Fixtures enter through fw_cfg; no installed disk or original source file is changed.
I64 gr_n,gr_m;
U8 *gr_src=HData("metadata.GR",&gr_n);
CDC *gr_dc=DCLoad(gr_src);
U8 *gr_out=DCSave(gr_dc,&gr_m,0);
HPrint("GR_METADATA width=%d height=%d stride=%d x0=%d y0=%d input=%d output=%d cmp=%d transparent=%d\n",
    gr_dc->width,gr_dc->height,gr_dc->width_internal,gr_dc->x0,gr_dc->y0,
    gr_n,gr_m,MemCmp(gr_src,gr_out,gr_n),GrPeek(gr_dc,0,0));
HPrint("BLOB original-metadata.GR %d\n",gr_m);
DbgPutN(gr_out,gr_m);
HPrint("\nEND-BLOB\n");
Free(gr_out);
DCDel(gr_dc);
Free(gr_src);

gr_src=HData("replay.GR",&gr_n);
gr_dc=DCLoad(gr_src);
gr_out=DCSave(gr_dc,&gr_m,0);
HPrint("GR_REPLAY width=%d height=%d input=%d output=%d cmp=%d body_fnv=%016X\n",
    gr_dc->width,gr_dc->height,gr_n,gr_m,MemCmp(gr_src,gr_out,gr_n),
    Fnv64(gr_dc->body,gr_dc->width_internal*gr_dc->height));
HPrint("BLOB original-replay.idx %d\n",gr_dc->width_internal*gr_dc->height);
DbgPutN(gr_dc->body,gr_dc->width_internal*gr_dc->height);
HPrint("\nEND-BLOB\n");
Free(gr_out);
DCDel(gr_dc);
Free(gr_src);

gr_src=HData("archive.GR.Z",&gr_n);
gr_out=ExpandBuf(gr_src);
gr_dc=DCLoad(gr_out);
HPrint("GR_ARCHIVE width=%d height=%d transparent=%d\n",gr_dc->width,gr_dc->height,GrPeek(gr_dc,0,0));
Free(gr_out);
DCDel(gr_dc);
Free(gr_src);

gr_src=HData("stadium.GR",&gr_n);
gr_dc=DCLoad(gr_src);
HPrint("GR_COMPRESSED width=%d height=%d stride=%d body_fnv=%016X\n",
    gr_dc->width,gr_dc->height,gr_dc->width_internal,
    Fnv64(gr_dc->body,gr_dc->width_internal*gr_dc->height));
HPrint("BLOB original-stadium.idx %d\n",gr_dc->width_internal*gr_dc->height);
DbgPutN(gr_dc->body,gr_dc->width_internal*gr_dc->height);
HPrint("\nEND-BLOB\n");
DCDel(gr_dc);
Free(gr_src);
