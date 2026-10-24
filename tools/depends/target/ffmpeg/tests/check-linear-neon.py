#!/usr/bin/env python3
"""Compare the patched FFmpeg kernel to its original scalar implementation on arm64.
Usage: check-linear-neon.py /path/to/patched/ffmpeg-source
Requires Apple Clang or an AArch64 C compiler. Uses ASan/UBSan, then benchmarks -O3.
"""
import pathlib, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
src = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='kodi-resample-test-') as tmp:
    tmp = pathlib.Path(tmp)
    (tmp / 'libswresample').mkdir()
    template = (src / 'libswresample/resample_template.c').read_text()
    (tmp / 'libswresample/resample_template.c').write_text(template)
    subprocess.run(['patch', '-R', '-p1', '-i', str(root / '001-aarch64-linear-float-resampler.patch')], cwd=tmp, check=True, stdout=subprocess.DEVNULL)
    reference = (tmp / 'libswresample/resample_template.c').read_text()
    (tmp / 'reference.c').write_text(reference.replace('N ## _float', 'N ## _reference'))
    (tmp / 'candidate.c').write_text(template)
    harness = root / 'tests/check-linear-neon.c'
    for mode, flags in [('sanitized', ['-O1', '-g', '-fsanitize=address,undefined']), ('optimized', ['-O3'])]:
        exe = tmp / mode
        subprocess.run(['clang', '-std=c11', *flags, '-I', str(tmp), str(harness), '-o', str(exe)], check=True)
        subprocess.run([str(exe), mode], check=True)
