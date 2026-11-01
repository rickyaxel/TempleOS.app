//Arrays: multi-dimensional, initializers, sizeof, row-major layout.
I64 a[2][3]={{1,2,3},{4,5,6}};
"%d %d %d\n",a[0][2],a[1][0],sizeof(a);
I64 *flat=a;
"%d %d\n",flat[4],*(flat+5);
I64 und[]={10,20,30,40};
"%d %d\n",sizeof(und),und[3];
U8 cube[2][3][4];
I64 i,j,k,sum=0;
for (i=0;i<2;i++) for (j=0;j<3;j++) for (k=0;k<4;k++) cube[i][j][k]=i*100+j*10+k;
for (i=0;i<24;i++) sum+=cube(U8*)[i];
"%d %d %d\n",cube[1][2][3],sizeof(cube),sum;
U16 h[4]={0xFFFF,1,2,3};
"%d %d\n",h[0],sizeof(h);
F64 fa[3]={0.5,1.5,2.5};
F64 fs=0;
for (i=0;i<3;i++) fs+=fa[i];
"%.1f %d\n",fs,sizeof(fa);
U8 *strs[3]={"zero","one","two"};
"%s %s %d\n",strs[2],strs[0],sizeof(strs);
U0 Fill(I64 *arr,I64 cnt) {I64 n; for (n=0;n<cnt;n++) arr[n]=n*n;}
I64 sq[5];
Fill(sq,5);
"%d %d\n",sq[4],sq[2];
"%d %d %d %d %d\n",sizeof(I64),sizeof(U8),sizeof(U0),sizeof(I32),sizeof(F64);
"%d %d %d\n",sizeof(U16),sizeof(Bool),sizeof(U8*);
//EXPECT:
//3 4 48
//5 6
//32 40
//123 24 1476
//65535 8
//4.5 24
//two zero 24
//16 4
//8 1 0 4 8
//2 1 8
