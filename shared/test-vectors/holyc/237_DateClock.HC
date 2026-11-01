// HolyC shifts bind before multiplication: retain the CDate fraction first.
CDateStruct ds;
Date2Struct(&ds,0x000B400080000000);
if (ds.hour!=12 || ds.min || ds.sec) throw('Assert');
Date2Struct(&ds,0x000B4000C0000000);
if (ds.hour!=18 || ds.min || ds.sec) throw('Assert');
"date-clock-ok\n";
//EXPECT:
//date-clock-ok
