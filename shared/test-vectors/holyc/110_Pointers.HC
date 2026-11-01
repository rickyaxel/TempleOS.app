//Pointer arithmetic scales by the pointed-to size; pointer difference is
//in elements; postfix typecasts change the pointed-to type (Doc/HolyC.DD).
I64 arr[4]={10,20,30,40};
I64 *p=arr,*q=&arr[3];
"%d %d %d\n",*(p+2),q-p,(q(U8*))-(p(U8*));
p++;
"%d\n",*p;
p+=2;
"%d\n",*p;
p--;
"%d\n",p[-1];
U8 *bytes=arr;
"%d\n",bytes[8];
*(bytes+16)(I64*)=99;
"%d\n",arr[2];
I64 **pp=&p;
**pp=5;
"%d\n",arr[2];
U16 *w=arr;
w[1]=1;
"%X\n",arr[0];
I32 *dw=arr;
dw+=1;
*dw=-1;
"%X\n",arr[0];
I64 x=42;
I64 *px=&x;
*px+=1;
(*px)++;
"%d\n",x;
U8 *s="abcdef";
U8 *e=s;
while (*e) e++;
"%d\n",e-s;
I64 Apply(I64 (*f)(I64 v),I64 v) {return f(v);}
I64 Neg(I64 v) {return -v;}
I64 Sq(I64 v) {return v*v;}
"%d %d\n",Apply(&Neg,5),Apply(&Sq,7);
"%d\n",NULL;
U8 *np=NULL;
"%d\n",!np;
//EXPECT:
//30 3 24
//20
//40
//20
//20
//99
//5
//1000A
//FFFFFFFF0001000A
//44
//6
//-5 49
//0
//1
