//Msg() shares the 256-message bound of posted input: a flood keeps the
//newest messages instead of growing host memory without limit.
I64 i;
for (i=0;i<100000;i++) Msg(MSG_KEY_DOWN,i,0);
"queued\n";
//EXPECT:
//queued
