"""Insert read-only counters into isolated build-tree copies of pinned upstream files.

Never edit the dependency checkout. Git blob IDs are from the locked core revision.
Any unrecognized source, non-unique anchor or in-place destination aborts the build.
"""
import hashlib
from pathlib import Path
import sys

PINS={'ControlStream.c':'d86f4cad40e717f50260aef07897896f48d180c3',
      'VideoStream.c':'a2def84e390c70245644d2e3cd0fcebffacf40f0',
      'VideoDepacketizer.c':'33faf735388418bc8c3f40ae78d314f9e7243d73',
      'RtpVideoQueue.c':'d5dbe94f60e6efe4d12c27392a0562c8eab5b2e6'}

def add(text,anchor,insert):
    if text.count(anchor)!=1:raise ValueError('nonunique_probe_anchor')
    return text.replace(anchor,insert+anchor)

def transform(name,data,normal_fec=False,guarded_retry=False):
    data=data.replace(b'\r\n',b'\n')
    if hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=PINS[name]:
        raise ValueError('unverified_core_source')
    s=data.decode('utf-8')
    if name=='ControlStream.c':
        s=add(s,'    // Request the IDR frame\n    PltSetEvent(&idrFrameRequiredEvent);',
              '    Limelog("sesame IDR intent\\n");\n')
    elif name=='VideoStream.c':
        s=add(s,'    waitingForVideoMs = 0;', '    if (encrypted) sr_socket(rtpSocket, 0);\n')
        s=add(s,'        if (err < minSize)', '        uint32_t sr_hint = 0;\n')
        s=add(s,'            if (encHeader->frameNumber &&',
            '            sr_hint = LE32(encHeader->frameNumber);\n            sr_read(rtpSocket, sr_hint);\n')
        s=add(s,'                continue;\n            }\n\n            if (!PltDecryptMessage',
            '                sr_old(sr_hint);\n')
        s=add(s,'                Limelog("Failed to decrypt video packet!', '                sr_bad(sr_hint);\n')
        s=add(s,'        if (queueStatus == RTPF_RET_QUEUED)', 
            '        if (encrypted) sr_auth(sr_hint, queueStatus == RTPF_RET_QUEUED);\n')
        s=add(s,'    if (buffer != NULL) {\n        free(buffer);','    if (encrypted) sr_socket(rtpSocket, 1);\n')
    elif name=='VideoDepacketizer.c':
        s=add(s,'                Limelog("Waiting for IDR frame', '                sr_mark(frameIndex, SR_WAIT_IDR);\n')
        s=add(s,'                Limelog("Waiting for RFI frame','                sr_mark(frameIndex, SR_WAIT_RFI);\n')
        s=add(s,'        reassembleFrame(frameIndex);','        sr_mark(frameIndex, SR_OUTPUT);\n')
        s=add(s,'    // We may not invalidate frames that', '    sr_mark(frameNumber, speculative ? SR_SPEC : SR_LOST);\n')
        s=add(s,'    // We may not invalidate frames that', '    if (!speculative) Limelog("sesame confirmed frame loss %u\\n", frameNumber);\n')
        if guarded_retry:
            anchor='                    LiRequestIdrFrame();\n                }\n            }\n            else {\n                // If we need an RFI frame first'
            if s.count(anchor)!=1:raise ValueError('nonunique_confirmed_wait')
            s=s.replace(anchor,anchor.replace('\n            }\n            else', '\n                else if (sesame_lan_retry_on_confirmed_wait()) {\n                    LiRequestIdrFrame();\n                }\n            }\n            else',1))
    else:
        # Keep LC_DEBUG, LC_ASSERT, FEC_VERBOSE, encryption, parity recovery and every
        # original receive branch. Only exclude the unit-test-style artificial erasure.
        if normal_fec:
            mark='#define FEC_VALIDATION_MODE\n'
            if s.count(mark)!=1:raise ValueError('unexpected_fec_selftest_guard')
            s=s.replace(mark,'/* isolated LAN playback: no synthetic FEC erasure */\n')
        s=add(s,'    while (queue->completedFecBlockList.count > 0) {\n        PRTPV_QUEUE_ENTRY entry',
              '    sr_mark(queue->currentFrameNumber, SR_FEC_COMPLETE);\n')
        s=add(s,'            if (queue->multiFecLastBlockNumber != 0) {\n                Limelog("Unrecoverable frame',
              '            sr_abandon(queue->currentFrameNumber, queue->pendingFecBlockList.count, queue->bufferDataPackets, (uint32_t)PltGetMillis());\n')
        s=add(s,'            Limelog("Unrecoverable frame %d: lost FEC blocks',
              '            sr_abandon(nvPacket->frameIndex, 0, 0, (uint32_t)PltGetMillis());\n')
        if guarded_retry:
            # This is the SUCCESS branch of queuePacket, before reconstructFrame can
            # synchronously queue an IDR. nvPacket is authenticated plaintext owned
            # by the queue, not the untrusted frame hint outside the GCM envelope.
            s=add(s,'        // Update total missing packet count',
                  '        if (EncryptionFeaturesEnabled & SS_ENC_VIDEO)\n'
                  '            sesame_lan_observe_admitted(nvPacket->frameIndex, !isBefore16(packet->sequenceNumber, queue->bufferFirstParitySequenceNumber));\n')
    return '#include "sesame_core_rx.h"\n'+s

def prepare(src,dst,normal_fec=False,guarded_retry=False):
    if dst==src or src in dst.parents or dst in src.parents:raise ValueError('destination_must_be_isolated')
    output={k:transform(k,(src/k).read_bytes(),normal_fec,guarded_retry) for k in PINS}
    dst.mkdir(parents=True,exist_ok=True)
    for k,v in output.items():
        out=dst/k
        if not out.is_file() or out.read_text(encoding='utf-8')!=v:
            out.write_text(v,encoding='utf-8',newline='\n')

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('out',type=Path)
    p.add_argument('--normal-fec',action='store_true');p.add_argument('--guarded-retry',action='store_true');a=p.parse_args()
    prepare(a.source.resolve(),a.out.resolve(),a.normal_fec,a.guarded_retry)
