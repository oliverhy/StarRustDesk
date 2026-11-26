"""Numeric evidence only for real-primary, encrypted Windows LAN capture. No desktop contents."""
from datetime import datetime
import re

LABELS={'Frame processing latency':'frame_processing', 'Network: each send_batch() latency':'send_batch',
        'Network: each FEC block latency':'fec_block', "Network: frame's overall network latency":'frame_network'}
NUMBER=r'(\d{1,5}(?:\.\d{1,4})?)ms'
STAGE_LINE=re.compile(r'\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\]: Debug: ('+
                      '|'.join(map(re.escape,LABELS))+r') \(min/max/avg\): '+('/'.join([NUMBER]*3)))


def stage_stat(line,now_ms):
    if len(line)>240:return None
    m=STAGE_LINE.fullmatch(line.strip())
    if not m:return None
    try:utc=round(datetime.strptime(m[1],'%Y-%m-%d %H:%M:%S.%f').timestamp()*1000)
    except (ValueError,OSError,OverflowError):return None
    lo,hi,mean=map(float,m.groups()[2:])
    if not -20<=now_ms-utc<=1500 or not 0<=lo<=mean<=hi<=30000:return None
    return dict(stage=LABELS[m[2]],utc_ms=utc,min_ms=lo,max_ms=hi,mean_ms=mean)
