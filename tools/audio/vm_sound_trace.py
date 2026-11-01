#!/usr/bin/env python3
"""Runs the Sound example on the original TempleOS V5.03 (reference VM) and records what it plays.

Two independent records come out of one run:

* timing: TempleOS's own sound recorder. While ScrnCast(ON,TRUE) is on, Snd() (Kernel/KMisc.HC) appends
  every call as a CSndData {ona, tS} to scrncast.snd_head; after the example the command line prints them
  as "ona:microseconds" from the first one. The screenshot vm-trace.png holds that printout.
* pitch: QEMU's PC speaker (pcspk) recorded through its wav audiodev (speaker.wav). QEMU only advances that
  recording while the speaker sounds, so it is used for frequencies, not durations (FA-33).

The example's statements are typed at the TempleOS prompt exactly as C:/Home/Examples/Sound.HC has them
(the file is not on the ISO; nothing on the ISO is changed). Before it, Beep plays ona 62 for 500 ms: a known
audible TempleOS sound that shows the VM's speaker recording works.

    python3 tools/audio/vm_sound_trace.py OUTDIR

Development tool only (QEMU, no network, official ISO). See docs/audio/TEMPLEOS_SOUND.md.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "reference-vm"))
from templeos_vm import TempleVM  # noqa: E402

EXAMPLE = ('"Scale with Snd():\\n";I64 ona;for (ona=60;ona<=72;ona+=2) {"%d ",ona;Snd(ona);Sleep(150);}'
           'Snd;"\\nA tune with Play():\\n";Play("4eCDEFGAB5C");"Done.\\n";')
TRACE = ('CSndData *d=scrncast.snd_head.next;F64 t0=d->tS;'
         'while (d!=&scrncast.snd_head) {"%d:%d ",d->ona,ToI64((d->tS-t0)*1000000);d=d->next;}"\\n";')


def main():
    out = os.path.abspath(sys.argv[1])
    os.makedirs(out, exist_ok=True)
    vm = TempleVM(out, wav=os.path.join(out, "speaker.wav"))
    try:
        vm.boot_to_shell()
        vm.cmd("AutoComplete;", settle=1.0)
        vm.cmd("Cd(\"::/Home\");", settle=0.5)
        vm.cmd("Beep;", settle=1.5)
        vm.cmd("ScrnCast(ON,TRUE);" + EXAMPLE + "ScrnCast(OFF);", settle=6.0)
        vm.cmd(TRACE, settle=2.0)
        vm.shot("vm-trace")
    finally:
        vm.quit()
    print(f"screenshot: {os.path.join(out, 'vm-trace.png')}  speaker: {os.path.join(out, 'speaker.wav')}")


if __name__ == "__main__":
    main()
