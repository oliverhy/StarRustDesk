"""First authenticated newer shard vs. native IDR, on one sealed view-only LAN session."""
import argparse
import json
from pathlib import Path
import re

import lan_key_path as key

SHARD = re.compile(r'lan_key_shard f=(\d{1,10}) first=(\d{1,16}) lf=(\d{1,10}) loss=(\d{1,16}) '
                   r'why=([012]) floor=(\d{1,10}) nf=(\d{1,10}) admit=(\d{1,16}) parity=([01]) reloss=([01])')


def classify(phase, output, shard, evidence, gap, previous_native=None):
    f, first, loss, wait, kind, q, sent, last, nq, ns = phase
    _, _, unit, surf, exact, idr, _, tries = output
    _, _, lf, recorded, why, floor, nf, admit, parity, reloss = shard
    if phase[:2] != output[:2] or phase[:2] != shard[:2] or recorded != loss or not 0 < first <= unit <= surf:
        raise ValueError('identity_or_time')
    if ((q==0)!=(nq==0) or (sent==0)!=(ns==0) or q and not first<=q<=unit or
        sent and not first<=sent<=last<=unit or wait and not first<=wait<=unit):
        raise ValueError('control_or_wait_clock')
    out=dict(recovery=f, first_loss_frame=lf or None, admitted_newer_frame=nf or None,
             discard_kind={0:None,1:'fec_abandon',2:'confirmed_depacketizer_loss'}[why],
             admitted_type=('parity' if parity else 'data') if admit else None, more_loss_before_native=bool(reloss),
             first_native_handoff_ms_after_loss=sent-loss if loss and sent else None,
             first_native_intent_ms_after_loss=q-loss if loss and q else None,
             loss_to_queue_admission_ms=admit-loss if loss and admit else None,
             admission_to_first_native_intent_ms=q-admit if admit and q else None,
             loss_to_exact_idr_surface_ms=surf-loss if loss and idr and exact else None,
             measured_surface_gap_ms=evidence.get('matched_surface_gap_ms'), measured_request_advance_ms=0,
             observed_margin_after_16ms_ms=None, display_improvement_ms=None)
    if not loss:
        if any(shard[2:]):raise ValueError('unconfirmed_progress')
        return dict(out,status='no_confirmed_video_loss')
    if not (first<=loss<=unit and why in (1,2) and 0<lf<=floor<f):
        raise ValueError('loss_frame_or_clock')
    if not admit:
        if nf or parity or reloss:raise ValueError('unmatched_shard')
        return dict(out,status='no_admitted_newer_fragment_observed')
    if not (floor<nf<=f and loss<=admit<=unit):
        raise ValueError('admission_out_of_epoch')
    if not (gap and gap[0]==unit and gap[2]==f and gap[1]<lf<f and gap[3]>0 and gap[7]==1 and idr and exact
            and evidence.get('encoder_idr_frame_match') and evidence.get('source_shards') and
            evidence.get('sent_shards')==evidence['source_shards']):
        return dict(out,status='not_exact_gap_and_host_idr_match')
    if kind!=1 or not wait or not q or not sent or not wait<=q<=sent or evidence.get('decoder_rejections'):
        return dict(out,status='not_native_first_idr_path')
    # Do not confuse an existing backup with the native first intent.
    backup=output[6]
    if tries and (not backup or q>=backup):
        return dict(out,status='first_intent_origin_ambiguous')
    if reloss:
        return dict(out,status='newer_picture_also_lost_before_request')
    if parity:
        return dict(out,status='first_admission_was_parity')
    if evidence.get('earlier_candidate_encoded_idrs') != []:
        return dict(out,status='earlier_host_idr_not_excluded')
    if previous_native is not None and loss-previous_native<750:
        return dict(out,status='inside_previous_control_cooldown')
    # A zero on a millisecond clock is not evidence of strictly earlier arrival.
    lead=max(0,q-max(loss+16,admit))
    return dict(out,status='earlier_opportunity' if lead else 'native_first_or_inside_guard',
                observed_margin_after_16ms_ms=lead)


def report(folder):
    evidence=key.join(folder)  # checks raw hashes, scope, single epoch, host IDR and Surface
    phone=json.loads((folder/'phone-numeric.json').read_bytes())
    events=phone['events']
    if sum(msg=='lan_key_shard_policy=1' for _,msg in events)!=1:
        return dict(status='observer_not_uniquely_observed',episodes=[],candidate_count=None)
    phases=key.slots(events,key.PHASE);outputs=key.slots(events,key.OUT);shards=key.slots(events,SHARD)
    if (phases.keys()!=outputs.keys() or phases.keys()!=shards.keys() or any(
            sum(rx.fullmatch(msg) is not None for _,msg in events)!=len(rows)
            for rx,rows in ((key.PHASE,phases),(key.OUT,outputs),(SHARD,shards)))):
        raise ValueError('missing_or_duplicate_observer_row')
    gaps={g[2]:g for g in phone['epochs'][0]['gap_events']}
    proof={e['frame']:e for e in evidence['episodes']}
    if (len(proof)!=len(evidence['episodes']) or len(proof)!=len(phases) or
            len(gaps)!=len(phone['epochs'][0]['gap_events'])):
        raise ValueError('ambiguous_frame_identity')
    rows=[];previous=None
    for k in sorted(phases,key=lambda k:k[1]):
        if k[0] not in proof:raise ValueError('episode_join_failed')
        phase=phases[k][1]
        rows.append(classify(phase,outputs[k][1],shards[k][1],proof[k[0]],gaps.get(k[0]),previous))
        if phase[7]:
            previous=max(previous or 0,phase[7])
    return dict(status='measured' if rows else 'no_completed_incidents',censored=evidence['censored'],
                episodes=rows,candidate_count=sum(x['status']=='earlier_opportunity' for x in rows),
                requests_changed=False,screen_advance_measured=False)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('folder',type=Path);p.add_argument('--save',action='store_true')
    a=p.parse_args();out=json.dumps(report(a.folder),indent=2,allow_nan=False)+'\n'
    if a.save:
        with (a.folder/'first-admitted-shard.json').open('x',encoding='ascii') as stream:stream.write(out)
    print(out,end='')
