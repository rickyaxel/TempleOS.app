//Sound: TempleOS plays notes on the PC speaker. Snd(ona) plays a
//piano key number; Play() takes a music string.

"Scale with Snd():\n";
I64 ona;
for (ona=60;ona<=72;ona+=2) {
  "%d ",ona;
  Snd(ona);
  Sleep(150);
}
Snd;
"\nA tune with Play():\n";
Play("4eCDEFGAB5C");
"Done.\n";
