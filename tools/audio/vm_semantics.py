#!/usr/bin/env python3
"""Measures TempleOS V5.03's own sound and timing semantics in the reference VM (docs/audio/TEMPLEOS_AUDIO_FIDELITY.md §4).

QEMU runs with -icount shift=auto and the RTC on the virtual clock, so the PIT (jiffies), the RTC and the CPU
all keep their relative rates even though TCG is slower than a real PC. Each probe is typed at the TempleOS
prompt (nothing on the ISO is changed) and its output is saved as a screenshot; the values printed on
2026-10-18 are in the docstrings below and in tools/audio/templeos_snd.py (VM_CASES, table hashes).

  arith     I64 += F64 as the x87 code does it                      printed  P:40 40 40   Q:39 40
  tables    hash of every nonzero ona's PIT count, of Freq2Ona       printed  H:F2B15FAF231EBC7F  F:43F7F076B2A8A3C0
  jiffies   jiffies counted over 20 CMOS-RTC second edges            printed  R:20019, R:20020 (expected 20019.8)
  sound     the Sound example's speaker changes, in jiffies           (VM_CASES["vm-sound-example"])
  complex   a Play string with meter, ties, triplets, dots, accidentals and a rest (VM_CASES["vm-play-complex"])

The speaker changes are recorded by a task on CPU 1 that polls scrncast.ona (Kernel/KMisc.HC Snd sets it) and
notes cnts.jiffies; the sound runs on CPU 1 too, away from the window manager, whose redraws on CPU 0 would
otherwise delay its wake-ups (on one CPU a Sleep(150) came out as 214 jiffies under TCG).

    python3 tools/audio/vm_semantics.py OUTDIR [probe ...]

Development tool only (QEMU, no network, official ISO). Compare: python3 tools/audio/templeos_snd.py --check-vm
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "reference-vm"))
from templeos_vm import TempleVM  # noqa: E402

POLL = ('I64 jt[80],ot[80],m=0,n;U0 PL(U8 *fp){I64 last=scrncast.ona;CTask *tk=Spawn(fp,NULL,"SE",1);'
        'while(TaskValidate(tk)&&m<80){if(scrncast.ona!=last){last=scrncast.ona;ot[m]=last;jt[m++]=cnts.jiffies;}Yield;}}')
SHOW = 'for(n=0;n<m;n++)"%d:%d ",ot[n],jt[n]-jt[0];"\\nJ0:%d M:%d\\n",jt[0],m;'

PROBES = {
    "arith": ['F64 o=400.0*(1.0-0.9);I64 a=60000,b=70000,c=300000,d=10,e=1000;a+=o;b+=o;c+=o;d+=o;e+=o;'
              '"P:%d %d %d Q:%d %d\\n",a-60000,b-70000,c-300000,d-10,e-1000;'],
    "tables": ['I64 h=0,k;for(k=-128;k<128;k++)if(k)h=h*31+ClampI64(SYS_TIMER_FREQ/Ona2Freq(k),1,U16_MAX);"H:%X\\n",h;'
               'h=0;for(k=1;k<=24000;k++)h=h*31+Freq2Ona(k*0.37);"F:%X\\n",h;'],
    "jiffies": ['CDateStruct dd;I64 s,i,j0,j1;Date2Struct(&dd,Now);s=dd.sec;while(dd.sec==s)Date2Struct(&dd,Now);'
                'j0=cnts.jiffies;for(i=0;i<20;i++){s=dd.sec;while(dd.sec==s)Date2Struct(&dd,Now);}j1=cnts.jiffies;'
                '"R:%d\\n",j1-j0;'],
    "sound": ['U0 SE(I64){I64 ona;for(ona=60;ona<=72;ona+=2){Snd(ona);Sleep(150);}Snd;Play("4eCDEFGAB5C");}',
              'm=0;Spawn(&PL,&SE,"PL",1);Sleep(5000);' + SHOW],
    "complex": ['U0 S2(I64){music.tempo=3.3;music.stacatto_factor=0.75;'
                'Play("M3/45qC(qCetDEF4h.GsA#Bb3wCRqCb6B#eAbqG");MusicSettingsRst;}',
                'm=0;Spawn(&PL,&S2,"PL",1);Sleep(6000);' + SHOW],
}
SETTLE = {"jiffies": 40, "sound": 10, "complex": 10}


def main():
    out = os.path.abspath(sys.argv[1])
    probes = sys.argv[2:] or list(PROBES)
    os.makedirs(out, exist_ok=True)
    vm = TempleVM(out, smp=2, extra_args=("-icount", "shift=auto"), rtc="base=localtime,clock=vm")
    try:
        time.sleep(20)
        for _ in range(2):          # the live CD's install and tour questions
            vm.key("n")
            time.sleep(5)
        vm.cmd(POLL, settle=2)
        for p in probes:
            for line in PROBES[p]:
                vm.cmd("DocClear;" + line, settle=SETTLE.get(p, 3))
            vm.shot(p)
            print(f"{p}: {os.path.join(out, p + '.png')}")
    finally:
        vm.quit()


if __name__ == "__main__":
    main()
