"""Reproducible offline checks against the exact core checkout used by the debug build."""
from pathlib import Path
import sys
from prepare import PINS,transform

def main(src):
    video_marker=b'Recovery error at %d: expected 0x00, actual 0x%02x'
    shared_marker=b'Recovery error at %d: expected 0x%02x, actual 0x%02x'
    audio=(src/'RtpAudioQueue.c').read_bytes()
    assert shared_marker in audio and video_marker not in audio
    for name in PINS:
        data=(src/name).read_bytes()
        a=transform(name,data);b=transform(name,data,True)
        if name=='RtpVideoQueue.c':
            assert video_marker in data and shared_marker in data
            assert a.replace('#define FEC_VALIDATION_MODE\n','/* isolated LAN playback: no synthetic FEC erasure */\n')==b
            assert '#define FEC_VERBOSE' in b and 'reed_solomon_reconstruct' in b
        else:assert a==b
        trial=transform(name,data,guarded_retry=True)
        if name=='VideoDepacketizer.c':
            assert trial.count('else if (sesame_lan_retry_on_confirmed_wait())')==1
            assert trial.index('if (waitingForNextSuccessfulFrame) {\n                    LiRequestIdrFrame();') < trial.index('else if (sesame_lan_retry_on_confirmed_wait())') < trial.index('// If we need an RFI frame first')
            assert trial.count('LiRequestIdrFrame();')==a.count('LiRequestIdrFrame();')+1
        elif name=='RtpVideoQueue.c':
            hook='        if (EncryptionFeaturesEnabled & SS_ENC_VIDEO)\n            sesame_lan_observe_admitted(nvPacket->frameIndex, !isBefore16(packet->sequenceNumber, queue->bufferFirstParitySequenceNumber));\n'
            assert trial.count(hook)==1 and trial.replace(hook,'')==a
            assert trial.index('if (!queuePacket(queue, packetEntry')<trial.index(hook)<trial.index('// Try to submit this frame.')
            vs=transform('VideoStream.c',(src/'VideoStream.c').read_bytes())
            assert vs.index('if (!PltDecryptMessage(')<vs.index('queueStatus = RtpvAddPacket')
        else:assert trial==a
        try:transform(name,data+b'\n')
        except ValueError:pass
        else:raise AssertionError('Unexpected input was accepted')
    print(f'pinned_witness_targets={len(PINS)} fec_delta_is_one_directive=1')
if __name__=='__main__': main(Path(sys.argv[1]))
