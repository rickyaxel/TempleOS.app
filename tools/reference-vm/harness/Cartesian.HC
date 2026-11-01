//Cartesian.HC: INSTRUMENTED DRIVER, not a TempleOS program. Evaluates the Cartesian formula
//corpus (shared/test-vectors/dynexpr/cartesian-corpus.json, flattened by fixtures.py into the data
//file "cartesian.txt") the way ::/Demo/Graphics/Cartesian.HC does:
//  F64 x,y,y_last;  ...  y=-ExePrint("ToF64(%s);",st)(F64);
//For every formula and sample it sets x=sample, y=0, y_last=0, calls ExePrint("ToF64(%s);",formula)
//inside try/catch (Cartesian itself has no try: an exception there ends the program) and prints
//  B <id> <sample bits>                                   before the call (hang/debugger culprit)
//  R <id> <sample bits> <result bits> <x> <y> <y_last> <except_ch hex> <cc_fix> <printed text>
//result bits = the I64 ExePrint returned (Cartesian reinterprets it as F64); except_ch = Fs->except_ch
//after the call (ExePutS catches 'Compiler' itself and returns 0, so a compile error shows here
//only, together with the compiler's printed message); printed text = what the call printed
//(captured from TempleOS's StdOut chain on the VM; the app has no such hook), escaped \n \\ \xHH.
//cc_fix = 1 when an exception other than 'Compiler' left ExePutS's CCmpCtrl queued in Fs (ExePutS
//skips its QueRem then); the harness unqueues it (VmIO.HC HCcMark/HCcRestore) so the next formula
//starts as a fresh Cartesian run. The app has no CCmpCtrl queue (AppIO.HC: always 0).
//Harness names all start with "cart_" so that no formula can see them.

F64 x,y,y_last;

I64 cart_n=0;
U8 *cart_hexd="0123456789ABCDEF";

I64 CartHex(U8 *s)
{
  I64 r=0,c;
  while (c=*s++) {
    if ('0'<=c<='9') r=r<<4+c-'0';
    else if ('A'<=c<='F') r=r<<4+c-'A'+10;
    else if ('a'<=c<='f') r=r<<4+c-'a'+10;
    else break;
  }
  return r;
}

U8 *CartEsc(U8 *s)
{//Escaped copy of printed text: printable ASCII as is, \n, \\, else \xHH.
  U8 *res,*d;
  I64 c;
  if (!s) return StrNew("");
  res=MAlloc(StrLen(s)*4+1);
  d=res;
  while (c=*s++) {
    if (c=='\\') {
      *d++='\\'; *d++='\\';
    } else if (c=='\n') {
      *d++='\\'; *d++='n';
    } else if (32<=c<127) {
      *d++=c;
    } else {
      *d++='\\'; *d++='x';
      *d++=cart_hexd[c>>4&15];
      *d++=cart_hexd[c&15];
    }
  }
  *d=0;
  return res;
}

U0 CartEval(U8 *cart_id,U8 *cart_st,I64 cart_sbits)
{
  I64 cart_res=0,cart_xb,cart_yb,cart_ylb,cart_fix=0;
  F64 cart_sample;
  I64 cart_cc=HCcMark;
  U8 *cart_cap,*cart_esc;
  MemCpy(&cart_sample,&cart_sbits,8);
  HPrint("B %s %016X\n",cart_id,cart_sbits);
  HProgress(++cart_n);
  x=cart_sample;
  y=0;
  y_last=0;
  Fs->except_ch=0;
  HCapBegin;
  try {
    cart_res=ExePrint("ToF64(%s);",cart_st);
  } catch {
    Fs->catch_except=TRUE;
  }
  cart_cap=HCapEnd;
  cart_fix=HCcRestore(cart_cc);
  MemCpy(&cart_xb,&x,8);
  MemCpy(&cart_yb,&y,8);
  MemCpy(&cart_ylb,&y_last,8);
  cart_esc=CartEsc(cart_cap);
  HPrint("R %s %016X %016X %016X %016X %016X %016X %d %s\n",cart_id,cart_sbits,
	cart_res,cart_xb,cart_yb,cart_ylb,Fs->except_ch,cart_fix,cart_esc);
  Free(cart_esc);
  Free(cart_cap);
}

U0 CartMain()
{//cartesian.txt: "S <hex bits>" lines (samples), then "F <id>\t<formula>" lines.
  I64 cart_size,cart_ns=0,i;
  I64 cart_samples[64];
  U8 *cart_buf=HData("cartesian.txt",&cart_size),*p,*e,*e2,*tab;
  if (!cart_buf) {
    HPrint("CART-NO-DATA\n");
    return;
  }
  HPrint("CART-START size=%d fnv=%016X\n",cart_size,Fnv64(cart_buf,cart_size));
  p=cart_buf;
  while (*p) {
    e=p;
    while (*e && *e!='\n') e++;
    if (*e) *e++=0;
    if (p[0]=='S' && p[1]==' ' && cart_ns<64)
      cart_samples[cart_ns++]=CartHex(p+2);
    else if (p[0]=='F' && p[1]==' ') {//every sample
      tab=p+2;
      while (*tab && *tab!='\t') tab++;
      if (*tab) {
	*tab++=0;
	for (i=0;i<cart_ns;i++)
	  CartEval(p+2,tab,cart_samples[i]);
      }
    } else if (p[0]=='G' && p[1]==' ') {//"G <id> <sample bits>\t<formula>": one sample
      tab=p+2;
      while (*tab && *tab!=' ') tab++;
      if (*tab) {
	*tab++=0;
	e2=tab;
	while (*tab && *tab!='\t') tab++;
	if (*tab) {
	  *tab++=0;
	  CartEval(p+2,tab,CartHex(e2));
	}
      }
    }
    p=e;
  }
  HPrint("CART-END n=%d\n",cart_n);
  Free(cart_buf);
}

CartMain;
