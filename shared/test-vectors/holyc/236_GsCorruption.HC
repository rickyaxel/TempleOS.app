// A program-visible CPU pointer must not redirect host window-manager writes.
// Regression: unchecked Gs->idle_factor access crashed the host during draw_it fuzzing.
U0 DrawIt(CTask *task,CDC *dc) { Gs=0x12345678; }
Fs->draw_it=&DrawIt;
Sleep(150);
"done\n";
//EXPECT:
//done
