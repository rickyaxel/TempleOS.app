//RoundTrip.HC: byte-exactness proof for the reference-VM channels (templeos_harness.py roundtrip).
//The host attaches 1 MiB (every byte value, then pseudo-random bytes) as fw_cfg file d/rt.bin;
//this reads it, prints its size and FNV-1a 64, and echoes the raw bytes back over port 0xE9.
I64 rt_size;
U8 *rt_buf=HData("rt.bin",&rt_size);
HPrint("RT size=%d fnv=%016X\n",rt_size,Fnv64(rt_buf,rt_size));
HPrint("BLOB rt.bin %d\n",rt_size);
DbgPutN(rt_buf,rt_size);
HPrint("\nEND-BLOB\n");
Free(rt_buf);
