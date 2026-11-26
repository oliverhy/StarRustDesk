"""Shadow the first IDR decision on sealed LAN telemetry; never send a request."""
import argparse
import json
from pathlib import Path

import core_rx_diag
import lan_key_path as keys


def shadow_first(events, grace_ms, *, secure=True, strict_idr=True, pending=False,
                 previous_request=None, cooldown_ms=750, require_progress=False):
    """One playback epoch/incident; input is receiver monotonic time, not wall time.

    Native decisions always win ties. An early decision would replace only the
    FIRST native intent (not its native retry). Never hold data or decode here.
    There's no wall-clock timer in the player as a result of running this model.
    """
    if min(grace_ms, cooldown_ms) < 0:
        raise ValueError('negative duration')
    priority = {'stop': 0, 'recovered': 0, 'native': 1, 'confirmed': 2,
                'speculative': 3, 'late': 3, 'decoder_reject': 3, 'progress': 3, 'tick': 4}
    events = list(events)
    if any(type(t) is not int or t < 0 or kind not in priority for t, kind in events):
        raise ValueError('unknown event or clock')
    # Only process a scheduled timer if the observed timeline reaches that point.
    confirmed = deadline = None
    for t, kind in sorted(events, key=lambda e: (e[0], priority[e[1]])):
        if deadline is not None and deadline < t:
            return 'early', deadline
        if kind in ('stop', 'recovered'):
            return 'cancelled', None
        if kind == 'native':
            return 'native', t
        if (kind == 'confirmed' and confirmed is None and secure and strict_idr and not pending
                and (previous_request is None or t - previous_request >= cooldown_ms)):
            confirmed = t
            if not require_progress:
                deadline = t + grace_ms
        if (kind == 'progress' and require_progress and confirmed is not None and t > confirmed
                and deadline is None):
            # A NEWER authenticated picture; an old packet arriving late cannot open this gate.
            deadline = max(confirmed + grace_ms, t)
        if kind == 'tick' and deadline == t:
            return 'early', t
    return 'unresolved', None


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def replay(folder, grace_ms=16):
    if type(grace_ms) is not int or not 0 <= grace_ms <= 100:
        raise ValueError('grace outside 0..100 ms')
    # The five original artifacts are verified by join() against the same capture.
    joined = keys.join(folder)
    phone = read(folder, 'phone-numeric.json')
    core = core_rx_diag.from_folder(folder)
    if (joined['status'] != 'measured' or joined['unmatched'] or joined['censored']
            or core['status'] != 'matched' or core['head_auth_failures']
            or {k: v for k, v in core.items() if k != 'heads'} != read(folder, 'result.json')['core_receive']):
        raise ValueError('incomplete or inconsistent epoch')
    phases = keys.slots(phone['events'], keys.PHASE)
    outputs = keys.slots(phone['events'], keys.OUT)
    witnesses = {e['frame']: e for e in joined['episodes']}
    heads = {h['f'] + h['n']: h for h in core['heads']}
    if (len(heads) != len(core['heads']) or phases.keys() != outputs.keys()
            or len(phases) != len(witnesses) or set(f for f, _ in phases) != set(heads)
            or set(heads) != set(witnesses)):
        raise ValueError('ambiguous or missing incident')
    previous = None
    rows = []
    for key in sorted(phases, key=lambda k: k[1]):
        f, first, loss, wait, kind, q, sent, last, nq, ns = phases[key][1]
        _, _, unit, surf, exact, idr, _, _ = outputs[key][1]
        h, e = heads[f], witnesses[f]
        if (not (first <= q <= sent <= last <= unit <= surf and first <= wait <= unit and nq >= ns >= 1)
                or loss and not first <= loss <= unit or previous is not None and previous >= first
                or exact != 1 or idr != 1 or not e['encoder_idr_frame_match']
                or e['sent_shards'] != e['source_shards'] or not e['sent_shards']
                or e['missing'] != h['n'] or e['first_evidence_to_surface_ms'] != surf - first):
            raise ValueError('invalid timeline or incomplete IDR evidence')
        # 'confirmed' is the episode's recorded firstLoss timestamp. Its branch
        # and exact per-frame FEC discard time are NOT in this trace. Late packets,
        # head flags and the later wait kind are corroboration, never input signals.
        comparable = bool(h['flags'] & 64 and h['late'] and h['boundary'] == 'all_read_by_core'
                          and kind == 1 and loss and not e['decoder_rejections'])
        if not comparable and not (not loss and e['decoder_rejections']):
            raise ValueError('unclassified incident: do not infer eligibility')
        stream = [(q, 'native'), (unit, 'recovered')]
        if comparable:
            stream.append((loss, 'confirmed'))
            # A completed non-IDR after the loss is definitely forward progress. No
            # frame-indexed phone timestamps for the *first fragment* of a newer frame
            # exist here. Do not substitute Windows send times or old late packets.
            if wait > loss:
                stream.append((wait, 'progress'))
        else:
            stream.append((first, 'decoder_reject'))
        def scenario(delay, require_progress=False):
            who, t = shadow_first(stream, delay, previous_request=previous, require_progress=require_progress)
            if who not in ('early', 'native'):
                raise ValueError('no first decision')
            return dict(first=who, intent_lead_ms=q - t)
        rows.append(dict(head=h['f'], recovery_idr=f, missing=h['n'],
                         group='late_after_discard' if comparable else 'local_decoder_control',
                         later_packets=h['late'], latest_packet_after_discard_ms=h['lag'] if h['late'] else None,
                         observed_loss_to_intent_ms=q-loss if loss else None,
                         observed_loss_to_control_ms=sent-loss if loss else None,
                         confirmed_to_recorded_complete_progress_ms=wait-loss if comparable and wait>loss else None,
                         first_newer_authenticated_fragment_ms=None,
                         observed_intent_to_recovered_surface_ms=surf-q,
                         recorded_surface_gap_ms=e['matched_surface_gap_ms'],
                         observed_intents=nq, observed_control_handoffs=ns,
                         host_control_candidates=e.get('host_control_candidates_since_previous_idr'),
                         other_recorded_idrs=e.get('earlier_candidate_encoded_idrs'),
                         immediate=scenario(0), guarded=scenario(grace_ms),
                         guarded_with_observed_progress=scenario(grace_ms, True),
                         counterfactual_display_gain_ms=None))
        previous = last  # later native retries are never removed by the model
    return dict(version=2, mode='offline_first_intent_only', grace_ms=grace_ms, cooldown_ms=750,
                clock='phone_monotonic_ms', assumptions=['authenticated H264 strict IDR path',
                'episode firstLoss is an eligible live signal; exact FEC discard time was not exported',
                'no unobserved pending request; guard timer wakes on time'],
                recorded_surface_retimed=False, episodes=rows)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('folder', type=Path)
    ap.add_argument('--grace-ms', type=int, default=16)
    ap.add_argument('--save', action='store_true', help='create a new numeric report; never overwrite')
    args = ap.parse_args()
    result = json.dumps(replay(args.folder, args.grace_ms), indent=2, allow_nan=False) + '\n'
    if args.save:
        with (args.folder / 'lan-first-idr-progress-replay.json').open('x', encoding='ascii') as out:
            out.write(result)
    print(result, end='')
