//TalonsUnmodified.HC: runs the UNMODIFIED ::/Demo/Games/Talons.HC from the CD with #include (as
//typing it at the prompt would), after turning on VmIO's all-task output copy so that an exception
//report printed by one of Talons' spawned tasks reaches console.log. Used for the guest-RAM runs
//(fixtures.py talons-mem). Talons then waits for keys in its game loop: the host stops the VM.
HMirrorAll(ON);
HMemSnap("before-Talons");
#include "::/Demo/Games/Talons.HC"
