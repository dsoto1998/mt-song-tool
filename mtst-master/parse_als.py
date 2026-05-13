#!/usr/bin/env python3
"""
parse_als.py  —  CLI backend for MT Song Tool Swift front-end.

Usage:  python3 parse_als.py <path/to/file.als>
Output: JSON to stdout
  {
    "error": null | "message",
    "file":  "filename.als",
    "markers": [{"time": "00:01:234", "text": "Verse 1"}, ...],
    "time_signatures": [{"time": "00:00:000", "sig": "4/4"}, ...]
  }
"""

import sys, os, json, re

# Ensure XML parsing works even if pyexpat is missing (e.g. macOS version mismatch).
# lxml bundles its own C libraries and doesn't depend on system pyexpat.
try:
    import xml.etree.ElementTree as _ET
    _ET.fromstring("<t/>")  # smoke test — will fail if pyexpat is broken
except Exception:
    import lxml.etree as _lxml_ET
    import xml.etree.ElementTree as _ET
    # Monkey-patch so dawtool uses lxml transparently
    _ET.fromstring = _lxml_ET.fromstring
    _ET.parse = _lxml_ET.parse
    _ET.Element = _lxml_ET.Element
    _ET.SubElement = _lxml_ET.SubElement
    _ET.ParseError = _lxml_ET.XMLSyntaxError

# Add mtst-master to path (works both standalone and from app bundle)
_here = os.path.dirname(os.path.abspath(__file__))
dawtool_root = os.environ.get("DAWTOOL_PATH", _here)
sys.path.insert(0, dawtool_root)


def fmt_time(seconds):
    from dawtool import format_time
    raw = format_time(seconds, False, precise=True)
    return raw.replace(".", ":")


def parse_time_signatures(proj):
    try:
        from dawtool.daw.ableton import AbletonProject
        if not isinstance(proj, AbletonProject):
            return []
    except ImportError:
        return []

    contents = proj.contents
    if not contents:
        return []

    def decode_ts(value):
        numerator   = (value % 99) + 1
        denom_index = value // 99
        denominator = 2 ** denom_index
        return numerator, denominator

    # Match dawtool's version-aware track name selection:
    #   Live < 10  → ArrangerAutomation (time sig extraction not supported here)
    #   Live 10/11 → MasterTrack
    #   Live 12+   → MainTrack
    # Note: use f"<{track_name}".encode() (no closing ">") so tags with
    # attributes — e.g. <MainTrack Id="0"> — are matched correctly.
    try:
        minor_a = proj.version.minorA
    except Exception:
        minor_a = 12  # safe default — try MainTrack

    if minor_a is not None and minor_a < 10:
        track_candidates = ()  # ArrangerAutomation layout not supported; skip to static fallback
    elif minor_a in (10, 11):
        track_candidates = ("MasterTrack",)
    else:
        track_candidates = ("MainTrack",)

    track_content = None
    for track_name in track_candidates:
        start = contents.find(f"<{track_name}".encode())   # no ">" — handles attributes
        if start == -1:
            continue
        end = contents.find(f"</{track_name}>".encode(), start)
        if end == -1:
            continue
        track_content = contents[start:end].decode("utf-8", errors="ignore")
        break

    # Find the AutomationEnvelope whose PointeeId matches the time sig target
    # Then extract EnumEvent entries from its Events block
    envelope_pattern = r"<AutomationEnvelope[^>]*>(.*?)</AutomationEnvelope>"
    pointee_pattern = r'<PointeeId\s+Value="(\d+)"'
    events_block_pattern = r"<Events>(.*?)</Events>"
    enum_event_pattern = r'<EnumEvent\s+[^>]*Time="([^"]+)"[^>]*Value="(\d+)"'

    results = []
    if track_content:
        ts_match = re.search(
            r"<TimeSignature>.*?<AutomationTarget Id=\"(\d+)\"",
            track_content, re.DOTALL
        )
        if ts_match:
            ts_target_id = ts_match.group(1)
            ae_match = re.search(
                r"<AutomationEnvelopes>(.*?)</AutomationEnvelopes>",
                track_content, re.DOTALL
            )
            if ae_match:
                ae_xml = ae_match.group(1)
                target_events_xml = None
                for env_match in re.finditer(envelope_pattern, ae_xml, re.DOTALL):
                    env_xml = env_match.group(1)
                    pid = re.search(pointee_pattern, env_xml)
                    if pid and pid.group(1) == ts_target_id:
                        ev_block = re.search(events_block_pattern, env_xml, re.DOTALL)
                        if ev_block:
                            target_events_xml = ev_block.group(1)
                        break
                if target_events_xml:
                    for ev in re.finditer(enum_event_pattern, target_events_xml):
                        beat = float(ev.group(1))
                        value = int(ev.group(2))
                        num, denom = decode_ts(value)
                        try:
                            if beat < 0:
                                # Ableton stores the initial time signature as a ghost event at
                                # beat -63072000. It represents the time signature from the very
                                # start of the arrangement, so we display it at 0:00:000.
                                real_time = 0.0
                            else:
                                real_time = proj._calc_beat_real_time(beat)
                            effective_beat = 0.0 if beat < 0 else beat
                            results.append((real_time, num, denom, effective_beat))
                        except Exception:
                            pass

    # Deduplicate: if the ghost initial event and a real beat-0 event both
    # landed at 0.0 with the same signature, keep only the first.
    seen = set()
    deduped = []
    for entry in sorted(results, key=lambda x: x[0]):
        key = (round(entry[0], 3), entry[1], entry[2])
        if key not in seen:
            seen.add(key)
            deduped.append(entry)  # (real_time, num, denom, beat)

    # Fallback: if envelope parsing produced nothing (e.g. a session with a single
    # unchanging time signature that Ableton stores statically rather than as an
    # automation envelope), read the static Numerator/Denominator fields instead.
    if not deduped:
        try:
            raw = contents.decode("utf-8", errors="ignore")
            num_m = re.search(r'<Numerator\s+Value="(\d+)"', raw)
            den_m = re.search(r'<Denominator\s+Value="(\d+)"', raw)
            ts_num = int(num_m.group(1)) if num_m else 4
            ts_den = int(den_m.group(1)) if den_m else 4
            deduped.append((0.0, ts_num, ts_den, 0.0))
        except Exception:
            pass

    return deduped


def _extract_locator_data(path):
    """Return list of (id, name_raw) sorted by beat time.

    Ableton stores locators in document order (which can differ from time order —
    e.g. a 'NEXT SONG' marker placed at beat 552 may appear first in the XML with
    Id="0").  Dawtool returns markers sorted by time, so we must sort the IDs the
    same way to keep the index mapping correct.

    We extract the locator name directly from the raw XML rather than using
    dawtool's m.text, because dawtool unconditionally calls .strip() on the Name
    value — which would silently hide leading/trailing-space errors.
    """
    import gzip, re, html as _html
    try:
        with gzip.open(path, "rb") as f:
            content = f.read().decode("utf-8", errors="ignore")
        # Find every <Locator Id="N">...</Locator> block
        blocks = re.findall(r'<Locator\s+Id="(\d+)"(.*?)</Locator>', content, re.DOTALL)
        result = []
        for loc_id, block in blocks:
            time_m = re.search(r'<Time\s+Value="([^"]+)"', block)
            name_m = re.search(r'<Name\s+Value="([^"]*)"', block)
            if time_m and name_m:
                raw_name = _html.unescape(name_m.group(1))
                result.append((loc_id, float(time_m.group(1)), raw_name))
        # Sort by beat time so indices match dawtool's time-sorted marker list
        result.sort(key=lambda x: x[1])
        return result  # list of (id, beat, name_raw)
    except Exception:
        return []


def _encode_ts(numerator, denominator):
    """Inverse of decode_ts used in parse_time_signatures.
    numerator: int (1-based), denominator: power of 2 (1, 2, 4, 8, 16, 32)
    Returns the Ableton EnumEvent Value integer.
    """
    import math
    denom_index = int(round(math.log2(max(1, denominator))))
    return (numerator - 1) + (denom_index * 99)


def _patch_tempo_events_in_content(content, tempo_events):
    """Replace the FloatEvent block inside the tempo AutomationEnvelope.

    tempo_events: list of {"beat": float, "bpm": float}, sorted, all beats >= 0.
    Step changes are encoded as two consecutive FloatEvents at the same beat:
    the first with the previous BPM (end of prior segment), the second with
    the new BPM (start of new segment) — matching Ableton's own convention.
    A phantom event at beat -63072000 is always prepended with the initial BPM.
    Returns the patched content string (unchanged if tempo envelope not found).
    """
    # Step 1: find the Tempo AutomationTarget Id (at LiveSet level, not track level).
    tempo_target_m = re.search(
        r"<Tempo\b[^>]*>.*?<AutomationTarget\s+Id=\"(\d+)\"",
        content, re.DOTALL
    )
    if not tempo_target_m:
        return content

    tempo_target_id = tempo_target_m.group(1)
    events_sorted = sorted(tempo_events, key=lambda e: float(e["beat"]))
    if not events_sorted:
        return content

    initial_bpm = float(events_sorted[0]["bpm"])

    # Build new FloatEvents XML lines.
    lines = []
    eid = 0

    def fe(time_val, bpm_val):
        nonlocal eid
        line = (f'<FloatEvent Id="{eid}" Time="{time_val}" Value="{bpm_val}" '
                f'CurveControl1X="0.5" CurveControl1Y="0.5" '
                f'CurveControl2X="0.5" CurveControl2Y="0.5"/>')
        eid += 1
        return line

    # Phantom anchor that Ableton always writes before the timeline origin.
    lines.append(fe(-63072000, initial_bpm))

    for i, ev in enumerate(events_sorted):
        beat = float(ev["beat"])
        bpm  = float(ev["bpm"])
        if i > 0:
            # Step change: emit hold event at this beat with previous BPM first.
            prev_bpm = float(events_sorted[i - 1]["bpm"])
            lines.append(fe(beat, prev_bpm))
        lines.append(fe(beat, bpm))

    new_events_xml = "\n                  ".join(lines)

    # Step 2: find the AutomationEnvelope with this PointeeId inside
    # MainTrack or MasterTrack and replace its <Events>…</Events> block.
    envelope_pattern = r"(<AutomationEnvelope[^>]*>)(.*?)(</AutomationEnvelope>)"

    for track_tag in ("MainTrack", "MasterTrack"):
        t_start = content.find(f"<{track_tag}")
        if t_start == -1:
            continue
        end_tag = f"</{track_tag}>"
        t_end = content.find(end_tag, t_start)
        if t_end == -1:
            continue
        t_end_full = t_end + len(end_tag)
        track_content = content[t_start:t_end_full]

        replaced = [False]

        def maybe_replace(m, _tid=tempo_target_id, _xml=new_events_xml, _r=replaced):
            env_inner = m.group(2)
            pid_m = re.search(r'<PointeeId\s+Value="(\d+)"', env_inner)
            if not pid_m or pid_m.group(1) != _tid:
                return m.group(0)
            new_inner = re.sub(
                r'<Events>.*?</Events>',
                f'<Events>\n                  {_xml}\n                </Events>',
                env_inner,
                flags=re.DOTALL
            )
            _r[0] = True
            return m.group(1) + new_inner + m.group(3)

        new_track = re.sub(envelope_pattern, maybe_replace, track_content, flags=re.DOTALL)
        if replaced[0]:
            content = content[:t_start] + new_track + content[t_end_full:]
            break

    return content


def _patch_time_sig_events_in_content(content, time_sig_events):
    """Replace the EnumEvent block inside the time-signature AutomationEnvelope.

    time_sig_events: list of {"beat": float, "numerator": int, "denominator": int}, sorted.
    A phantom event at beat -63072000 is always prepended with the initial time sig.
    Returns the patched content string (unchanged if time sig envelope not found).
    """
    import math

    events_sorted = sorted(time_sig_events, key=lambda e: float(e["beat"]))
    if not events_sorted:
        return content

    initial_val = _encode_ts(int(events_sorted[0]["numerator"]), int(events_sorted[0]["denominator"]))

    envelope_pattern = r"(<AutomationEnvelope[^>]*>)(.*?)(</AutomationEnvelope>)"

    for track_tag in ("MainTrack", "MasterTrack"):
        t_start = content.find(f"<{track_tag}")
        if t_start == -1:
            continue
        end_tag = f"</{track_tag}>"
        t_end = content.find(end_tag, t_start)
        if t_end == -1:
            continue
        t_end_full = t_end + len(end_tag)
        track_content = content[t_start:t_end_full]

        # Find the TimeSignature AutomationTarget Id inside this track.
        ts_target_m = re.search(
            r"<TimeSignature>.*?<AutomationTarget\s+Id=\"(\d+)\"",
            track_content, re.DOTALL
        )
        if not ts_target_m:
            continue

        ts_target_id = ts_target_m.group(1)

        # Build new EnumEvents XML.
        lines = []
        eid = 0

        def ee(time_val, value):
            nonlocal eid
            line = f'<EnumEvent Id="{eid}" Time="{time_val}" Value="{value}"/>'
            eid += 1
            return line

        lines.append(ee(-63072000, initial_val))
        for ev in events_sorted:
            beat = float(ev["beat"])
            val  = _encode_ts(int(ev["numerator"]), int(ev["denominator"]))
            lines.append(ee(beat, val))

        new_events_xml = "\n                  ".join(lines)
        replaced = [False]

        def maybe_replace_ts(m, _tid=ts_target_id, _xml=new_events_xml, _r=replaced):
            env_inner = m.group(2)
            pid_m = re.search(r'<PointeeId\s+Value="(\d+)"', env_inner)
            if not pid_m or pid_m.group(1) != _tid:
                return m.group(0)
            new_inner = re.sub(
                r'<Events>.*?</Events>',
                f'<Events>\n                  {_xml}\n                </Events>',
                env_inner,
                flags=re.DOTALL
            )
            _r[0] = True
            return m.group(1) + new_inner + m.group(3)

        new_track = re.sub(envelope_pattern, maybe_replace_ts, track_content, flags=re.DOTALL)
        if replaced[0]:
            content = content[:t_start] + new_track + content[t_end_full:]
            break

    return content


def _save_als_edits(path, tempo_events, time_sig_events, locator_overrides, new_locators=None, output_path=None):
    """Patch tempo map, time signatures, and locator positions/names.

    When output_path is None: backs up the original to OLD_<basename>.als and
    overwrites the original (in-place save).
    When output_path is provided: writes to output_path without touching the
    original file (Save As).

    tempo_events: list of {"beat": float, "bpm": float} — beats >= 0, sorted
    time_sig_events: list of {"beat": float, "numerator": int, "denominator": int}
    locator_overrides: list of {"als_id": str, "beat": float|null, "name": str|null}
    new_locators: list of {"beat": float, "name": str} — new locators to insert

    Returns {"ok": True, "new_path": "..."} or {"error": "..."}.
    """
    import gzip, os

    dir_name  = os.path.dirname(path)
    base_name = os.path.basename(path)
    old_path  = os.path.join(dir_name, "OLD_" + base_name)

    try:
        with gzip.open(path, "rb") as f:
            content = f.read().decode("utf-8")

        # 1. Tempo map
        if tempo_events:
            content = _patch_tempo_events_in_content(content, tempo_events)

        # 2. Time signatures
        if time_sig_events:
            content = _patch_time_sig_events_in_content(content, time_sig_events)

        # 3. Locator positions and/or names
        for ov in locator_overrides:
            als_id = re.escape(str(ov["als_id"]))
            beat   = ov.get("beat")
            name   = ov.get("name")
            if beat is None and name is None:
                continue

            def patch_locator(m, _beat=beat, _name=name):
                block = m.group(0)
                if _beat is not None:
                    block = re.sub(
                        r'(<Time\s+Value=")[^"]*(")',
                        rf'\g<1>{_beat}\g<2>',
                        block
                    )
                if _name is not None:
                    escaped_name = str(_name).replace("&", "&amp;").replace('"', "&quot;")
                    block = re.sub(
                        r'(<Name\s+Value=")[^"]*(")',
                        rf'\g<1>{escaped_name}\g<2>',
                        block
                    )
                return block

            content = re.sub(
                rf'<Locator\s+Id="{als_id}".*?</Locator>',
                patch_locator,
                content,
                flags=re.DOTALL,
            )

        # 4. Insert new locators
        if new_locators:
            existing_ids = [int(m) for m in re.findall(r'<Locator\s+Id="(\d+)"', content)]
            next_id = (max(existing_ids) + 1) if existing_ids else 1
            indent = '\t\t\t'
            new_xml = ''
            for i, loc in enumerate(sorted(new_locators, key=lambda x: x['beat'])):
                escaped = str(loc['name']).replace('&', '&amp;').replace('"', '&quot;')
                new_xml += (
                    f'\n{indent}<Locator Id="{next_id + i}">'
                    f'\n{indent}\t<LomId Value="0" />'
                    f'\n{indent}\t<Time Value="{repr(float(loc["beat"]))}" />'
                    f'\n{indent}\t<Name Value="{escaped}" />'
                    f'\n{indent}\t<Annotation Value="" />'
                    f'\n{indent}\t<IsSongStart Value="false" />'
                    f'\n{indent}</Locator>'
                )
            # Handle self-closing <Locators /> vs populated block
            if re.search(r'<Locators\s*/>', content):
                content = re.sub(
                    r'<Locators\s*/>',
                    f'<Locators>{new_xml}\n{indent[:-1]}</Locators>',
                    content, count=1
                )
            else:
                content = re.sub(r'(</Locators>)', new_xml + r'\n\1', content, count=1)

        # Write patched content
        if output_path:
            # Save As: write to new location, leave original untouched
            with gzip.open(output_path, "wb") as f:
                f.write(content.encode("utf-8"))
            return {"ok": True, "new_path": output_path}
        else:
            # In-place save: backup then overwrite
            os.rename(path, old_path)
            try:
                with gzip.open(path, "wb") as f:
                    f.write(content.encode("utf-8"))
            except Exception as e:
                try:
                    os.rename(old_path, path)
                except Exception:
                    pass
                return {"error": str(e)}
            return {"ok": True, "new_path": path}

    except Exception as e:
        return {"error": str(e)}


def _fix_locators(path, fixes):
    """
    Patch locator names in-place, keeping the original filename.
    The original file is first renamed to OLD_<basename>.als as a backup.
    fixes: list of {"als_id": "123", "new_name": "CHORUS"}
    Returns {"ok": True, "new_path": "/…/Session.als"} or {"error": "…"}.
    """
    import gzip, os, re

    dir_name  = os.path.dirname(path)
    base_name = os.path.basename(path)
    old_path  = os.path.join(dir_name, "OLD_" + base_name)

    try:
        # Read original content before touching anything on disk
        with gzip.open(path, "rb") as f:
            content = f.read().decode("utf-8")

        for fix in fixes:
            als_id   = re.escape(str(fix["als_id"]))
            new_name = fix["new_name"].replace("&", "&amp;").replace('"', "&quot;")

            def patch_block(m, _new=new_name):
                return re.sub(
                    r'(<Name\s+Value=")[^"]*(")',
                    rf'\g<1>{_new}\g<2>',
                    m.group(0)
                )

            content = re.sub(
                rf'<Locator\s+Id="{als_id}".*?</Locator>',
                patch_block,
                content,
                flags=re.DOTALL,
            )

        # Rename original → OLD_* then write patched content to the original path
        os.rename(path, old_path)
        try:
            with gzip.open(path, "wb") as f:
                f.write(content.encode("utf-8"))
        except Exception as e:
            # Write failed — restore original so nothing is lost
            try:
                os.rename(old_path, path)
            except Exception:
                pass
            return {"error": str(e)}

        return {"ok": True, "new_path": path}

    except Exception as e:
        return {"error": str(e)}


def _downgrade_to_live11(path):
    """Convert a Live 12 .als file to be compatible with Ableton Live 11.

    Writes to <name>_Live11.als in the same directory (non-destructive).
    Returns {"ok": True, "new_path": "/path/to/Session_Live11.als"}
         or {"error": "..."}.
    """
    import gzip, os, re

    try:
        with gzip.open(path, "rb") as f:
            content = f.read().decode("utf-8")
    except Exception as e:
        return {"error": f"Could not read file: {e}"}

    if 'MinorVersion="12.' not in content:
        return {"error": "This session does not appear to be a Live 12 file."}

    # 1. Version header
    content = re.sub(r'(<Ableton\b[^>]*?)MinorVersion="[^"]*"',
                     r'\1MinorVersion="11.0_11300"', content)
    content = re.sub(r'(<Ableton\b[^>]*?)Creator="[^"]*"',
                     r'\1Creator="Ableton Live 11.3.43"', content)
    content = re.sub(r'\s*SchemaChangeCount="[^"]*"', '', content)

    # 2. MainTrack → MasterTrack (rename tag, strip Live-12 attributes, fix EffectiveName)
    main_m = re.search(r'<MainTrack\b[^>]*>', content)
    if main_m:
        main_start = main_m.start()
        close_tag  = '</MainTrack>'
        main_end   = content.find(close_tag, main_start)
        if main_end != -1:
            main_end += len(close_tag)
            block = content[main_start:main_end]
            block = re.sub(r'^<MainTrack\b[^>]*>', '<MasterTrack>', block)
            block = re.sub(r'(<EffectiveName\s+Value=")Main(")', r'\1Master\2',
                           block, count=1)
            block = block.replace('</MainTrack>', '</MasterTrack>')
            content = content[:main_start] + block + content[main_end:]

    # 3. IsSongTempoLeader → IsSongTempoMaster (inside every clip)
    content = content.replace('<IsSongTempoLeader ', '<IsSongTempoMaster ')

    # 4. AutoColorPickerForReturnAndMainTracks rename
    content = content.replace(
        'AutoColorPickerForReturnAndMainTracks',
        'AutoColorPickerForReturnAndMasterTracks'
    )

    # 5. Strip Live-12-only attributes from any track opening tag
    for attr in ('SelectedToolPanel', 'SelectedTransformationName', 'SelectedGeneratorName'):
        content = re.sub(rf'\s+{attr}="[^"]*"', '', content)

    # 6. Remove Live-12 clip fields unknown to Live 11
    # NOTE: IsInKey, ScaleInformation, ContentLanes, ExpressionLanes exist in Live 11 — do NOT strip those
    content = re.sub(r'\s*<AutoWarpPending\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<WasMuted\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<SamplesToAutoWarp\s+Value="[^"]*"\s*/>', '', content)

    # 7. Replace ViewStates block with the Live 11 schema
    live11_viewstates = (
        '<ViewStates>\n'
        '\t\t\t<SessionIO Value="1" />\n'
        '\t\t\t<SessionSends Value="1" />\n'
        '\t\t\t<SessionReturns Value="1" />\n'
        '\t\t\t<SessionMixer Value="1" />\n'
        '\t\t\t<SessionTrackDelay Value="0" />\n'
        '\t\t\t<SessionCrossFade Value="0" />\n'
        '\t\t\t<SessionShowOverView Value="0" />\n'
        '\t\t\t<ArrangerIO Value="1" />\n'
        '\t\t\t<ArrangerReturns Value="1" />\n'
        '\t\t\t<ArrangerMixer Value="1" />\n'
        '\t\t\t<ArrangerTrackDelay Value="0" />\n'
        '\t\t\t<ArrangerShowOverView Value="1" />\n'
        '\t\t</ViewStates>'
    )
    content = re.sub(r'<ViewStates>.*?</ViewStates>', live11_viewstates,
                     content, flags=re.DOTALL)

    # 8. Remove Live-12 ViewStateMainWindow*/ViewStateSecondWindow* elements
    for pat in (
        r'\s*<ViewStateMainWindowClipDetailOpen\s+Value="[^"]*"\s*/>',
        r'\s*<ViewStateMainWindowHiddenOtherDocViewTypeClipDetailOpen\s+Value="[^"]*"\s*/>',
        r'\s*<ViewStateMainWindowHiddenOtherDocViewTypeDeviceDetailOpen\s+Value="[^"]*"\s*/>',
        r'\s*<ViewStateMainWindowDeviceDetailOpen\s+Value="[^"]*"\s*/>',
        r'\s*<ViewStateSecondWindowClipDetailOpen\s+Value="[^"]*"\s*/>',
        r'\s*<ViewStateSecondWindowDeviceDetailOpen\s+Value="[^"]*"\s*/>',
    ):
        content = re.sub(pat, '', content)

    # 9. Insert Live 11 ViewState detail elements before <ViewStates>
    content = content.replace(
        '<ViewStates>',
        '<ViewStateArrangerHasDetail Value="true" />\n'
        '\t\t<ViewStateSessionHasDetail Value="true" />\n'
        '\t\t<ViewStateDetailIsSample Value="false" />\n'
        '\t\t<ViewStates>',
        1  # only the first (and only) occurrence
    )

    # 10. Remove Live-12 NoteAlgorithms block (MIDI transform panel)
    content = re.sub(r'\s*<NoteAlgorithms>.*?</NoteAlgorithms>', '',
                     content, flags=re.DOTALL)

    # 11. Remove TuningSystems element
    content = re.sub(r'\s*<TuningSystems\s*/>', '', content)

    # 12. Replace Live-12 top-level SessionScrollPos with Live-11 SongMasterValues
    content = re.sub(
        r'<SessionScrollPos\s+X="[^"]*"\s+Y="[^"]*"\s*/>',
        '<SongMasterValues>\n\t\t\t<SessionScrollerPos X="0" Y="0" />\n\t\t</SongMasterValues>',
        content
    )

    # 13. Remove Live-12 track structure elements unknown to Live 11
    # NOTE: <TakeLanes> is NOT stripped — it exists identically in Live 11 and is required.
    # Only <TakeLanesListWrapper> (a Live-12 LOM wrapper) and <ArrangementClipsListWrapper> are new.
    content = re.sub(r'\s*<TakeLanesListWrapper\b[^>]*/>', '', content)
    content = re.sub(r'\s*<ArrangementClipsListWrapper\b[^>]*/>', '', content)

    # 14. Remove Live-12 MIDI features
    content = re.sub(r'\s*<NoteProbabilityGroups\s*/>', '', content)
    content = re.sub(r'\s*<ProbabilityGroupIdGenerator>.*?</ProbabilityGroupIdGenerator>', '',
                     content, flags=re.DOTALL)
    content = re.sub(r'\s*<NoteAlgorithms>.*?</NoteAlgorithms>', '', content, flags=re.DOTALL)
    content = re.sub(r'\s*<MpePitchBendUsesTuning\s+Value="[^"]*"\s*/>', '', content)

    # 14b. Strip Live-12 MidiClip / AudioClip clip-level additions unknown to Live 11.
    # ExpressionGrid — Live 12 MPE expression lane data; Live 11 has no such stream type,
    # triggering "Unknown Compound Stream Type" when Live 11 tries to deserialise it.
    content = re.sub(r'\s*<ExpressionGrid>.*?</ExpressionGrid>', '', content, flags=re.DOTALL)
    # ScaleInformation inside AudioClip — Live 12 added per-clip scale data to audio clips;
    # Live 11 crashes (EXC_BAD_ACCESS at +8) when it finds ScaleInformation in an AudioClip.
    # MidiClip ScaleInformation is KEPT — Live 11 expects it in MidiClips (removing it causes
    # the same null-deref crash). Steps 21+22 below handle Root→RootNote rename and int→string
    # Name conversion for all remaining ScaleInformation blocks (LiveSet + MidiClip).
    content = re.sub(
        r'(<AudioClip\b[^>]*>)(.*?)(</AudioClip>)',
        lambda m: m.group(1)
            + re.sub(r'\s*<ScaleInformation>.*?</ScaleInformation>', '', m.group(2), flags=re.DOTALL)
            + m.group(3),
        content, flags=re.DOTALL,
    )
    # AccidentalSpellingPreference / PreferFlatRootNote — Live 12 MidiClip view fields.
    content = re.sub(r'\s*<AccidentalSpellingPreference\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<PreferFlatRootNote\s+Value="[^"]*"\s*/>', '', content)
    # NoteEditorFold* — Live 12 piano-roll fold view state fields not present in Live 11.
    content = re.sub(r'\s*<NoteEditorFold\w+\s+Value="[^"]*"\s*/>', '', content)

    # 15. Remove Live-12 device/modulation fields
    content = re.sub(r'\s*<BreakoutIsExpanded\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<EnabledByUser\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<IsTuned\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<KeepRecordMonitoringLatency\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<ComplexProEnvelopeModulationTarget\b.*?</ComplexProEnvelopeModulationTarget>',
                     '', content, flags=re.DOTALL)
    content = re.sub(r'\s*<ComplexProFormantsModulationTarget\b.*?</ComplexProFormantsModulationTarget>',
                     '', content, flags=re.DOTALL)
    content = re.sub(r'\s*<TransientEnvelopeModulationTarget\b.*?</TransientEnvelopeModulationTarget>',
                     '', content, flags=re.DOTALL)
    content = re.sub(r'\s*<SourceHint\b[^>]*/>', '', content)
    content = re.sub(r'\s*<SourceHint\b.*?</SourceHint>', '', content, flags=re.DOTALL)

    # 15b. Strip Live-12 ViewData from inside Mixer/MainSequencer/FreezeSequencer sub-nodes.
    # In Live 12 these nodes gained a <ViewData Value="{...}" /> child immediately after
    # <SourceContext>.  Live 11's deserializer has no field for it; when the object graph is
    # later traversed Live 11 reads an uninitialised pointer → EXC_BAD_ACCESS at offset +8.
    # The top-level track <ViewData> (which follows <ClipSlotsListWrapper>) is NOT stripped —
    # it exists identically in Live 11 and must be kept.
    content = re.sub(r'(</SourceContext>)\n([ \t]*)<ViewData\s+Value="[^"]*"\s*/>',
                     r'\1', content)

    # 15c. Strip <MidiControllerRange> from inside <CrossFadeState>.
    # Live 12 added MidiControllerRange as a child of CrossFadeState; Live 11's CrossFadeState
    # struct does not have this field — leaving it causes a null-deref crash on the MIDI
    # controller map when Live 11 initialises the mixer.
    content = re.sub(
        r'(<CrossFadeState>.*?</AutomationTarget>)\s*<MidiControllerRange>.*?</MidiControllerRange>(\s*</CrossFadeState>)',
        r'\1\2',
        content, flags=re.DOTALL,
    )

    # 15d. Strip <IsInKey> from AudioClip — Live 12 addition, not present in Live 11 clips.
    content = re.sub(r'\s*<IsInKey\s+Value="[^"]*"\s*/>', '', content)


    # 15e. Strip <MidiControllerRange> from inside <TimeSignature> in MasterTrack Mixer.
    # Live 12 added MidiControllerRange as a child of TimeSignature; Live 11's TimeSignature
    # struct does not have this field.
    content = re.sub(
        r'(<TimeSignature>\s*<LomId[^/]*/>\s*<Manual[^/]*/>\s*<AutomationTarget\b[^>]*>.*?</AutomationTarget>)'
        r'\s*<MidiControllerRange>.*?</MidiControllerRange>(\s*</TimeSignature>)',
        r'\1\2',
        content, flags=re.DOTALL,
    )

    # 15f. Strip <Mapping> from individual <Locator> elements.
    # Live 12 added per-locator MIDI key mappings; Live 11 uses only the global
    # NextLocatorMapping/PreviousLocatorMapping at the Locators level.
    content = re.sub(r'\s*<Mapping>.*?</Mapping>', '', content, flags=re.DOTALL)

    # 15g. Strip <NoteSpellingPreference> from LiveSet — Live 12 session-level addition.
    content = re.sub(r'\s*<NoteSpellingPreference\s+Value="[^"]*"\s*/>', '', content)

    # 16. Remove Live-12 top-level session fields
    content = re.sub(r'\s*<SelectedDocumentViewInMainWindow\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<ShouldSceneTempoAndTimeSignatureBeVisible\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<WaveformVerticalZoomFactor\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<IsWaveformVerticalZoomActive\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<GroovesListWrapper\b[^>]*/>', '', content)
    content = re.sub(r'\s*<DefaultGrooveId\s+Value="[^"]*"\s*/>', '', content)

    # 17. Remove Live-12 locator key-mapping element (Live 11 uses Next/PreviousLocatorMapping)
    content = re.sub(r'\s*<SetLocatorMapping>.*?</SetLocatorMapping>', '', content, flags=re.DOTALL)

    # 18. Remove Live-12 ViewState dimension fields
    content = re.sub(r'\s*<ViewStateArrangerMixerVolumeSectionHeight\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<ViewStateSessionMixerVolumeSectionHeight\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<ViewStateSessionTrackWidth\s+Value="[^"]*"\s*/>', '', content)

    # 19. Rename MidiEditorLaneModel → ExpressionLane (renamed in Live 12)
    content = content.replace('<MidiEditorLaneModel ', '<ExpressionLane ')
    content = content.replace('</MidiEditorLaneModel>', '</ExpressionLane>')

    # 19b. Strip ExpressionLane entries with Type > 4 from ExpressionLanes/ContentLanes.
    # Live 12 added Type=5 (Note Probability) to the expression lane enum. Live 11's enum
    # only has types 0–4 (velocity + 4 MPE streams). Deserialising Type=5 returns a null
    # lane object; calling a virtual method through it → PAC failure (pointer auth crash).
    # Must run AFTER step 19 so the renamed <ExpressionLane> tags are in place.
    def _strip_unknown_expression_lanes(block):
        def _drop_lane(m):
            lane_xml = m.group(0)
            t = re.search(r'<Type Value="(\d+)"', lane_xml)
            if t and int(t.group(1)) > 4:
                return ''
            return lane_xml
        return re.sub(r'\s*<ExpressionLane\b[^>]*>.*?</ExpressionLane>', _drop_lane,
                      block, flags=re.DOTALL)
    content = re.sub(
        r'(<(?:ExpressionLanes|ContentLanes)>)(.*?)(</(?:ExpressionLanes|ContentLanes)>)',
        lambda m: m.group(1) + _strip_unknown_expression_lanes(m.group(2)) + m.group(3),
        content, flags=re.DOTALL
    )

    # 20. Remove remaining Live-12 session fields
    content = re.sub(r'\s*<SelectedBreakpointValue\s+Value="[^"]*"\s*/>', '', content)

    # 21. Rename Root → RootNote inside ScaleInformation (tag renamed in Live 12)
    content = content.replace('<Root Value=', '<RootNote Value=')
    content = content.replace('</Root>', '</RootNote>')

    # 22. Map ScaleInformation/Name integer index → string name.
    # Live 12 stores scale mode as an integer (e.g. "0"); Live 11 stores a string (e.g. "Major").
    # Live 11's parser does a string-table lookup; unrecognised value returns null → crash at +8.
    _scale_names = [
        "Major", "Minor", "Dorian", "Mixolydian", "Lydian", "Phrygian", "Locrian",
        "Whole Tone", "Half-whole Dim.", "Whole-half Dim.", "Minor Blues",
        "Minor Pentatonic", "Major Pentatonic", "Harmonic Minor", "Melodic Minor",
        "Super Locrian", "Bhairav", "Hungarian Minor", "Minor Gypsy", "Hirajoshi",
        "In-Sen", "Iwato", "Kumoi", "Pelog Selisir", "Pelog Tembung",
        "Messiaen 3", "Messiaen 4", "Messiaen 5", "Messiaen 6", "Messiaen 7",
        "Enigmatic", "Persian", "Arabian", "Japanese", "Egyptian", "Hawaiian",
        "Spanish Gypsy", "Byzantine", "Leading Whole Tone", "Augmented",
        "Neopolitan", "Neopolitan Minor", "Major Locrian", "Purvi Theta",
        "Todi Theta", "Chinese",
    ]
    def _fix_scale_name_block(m):
        block = m.group(0)
        def _sub(m2):
            val = m2.group(1)
            if val.lstrip('-').isdigit():
                idx = int(val)
                name = _scale_names[idx] if 0 <= idx < len(_scale_names) else "Major"
                return '<Name Value="{}" />'.format(name)
            return m2.group(0)
        return re.sub(r'<Name Value="([^"]*)" />', _sub, block)
    content = re.sub(r'<ScaleInformation>.*?</ScaleInformation>',
                     _fix_scale_name_block, content, flags=re.DOTALL)

    # 23. Add <Active Value="true" /> to every TrackSendHolder.
    # Live 12 dropped this element; Live 11 requires it — missing it leaves the active-target
    # pointer uninitialised, causing a null-deref crash when Live 11 renders the mixer.
    content = re.sub(
        r'^([ \t]*)(</TrackSendHolder>)',
        r'\1\t<Active Value="true" />\n\1\2',
        content,
        flags=re.MULTILINE,
    )

    # 24. Add <ChooserBar Value="0" /> after <CuePointsListWrapper> (present in Live 11, absent in Live 12)
    content = re.sub(
        r'(<CuePointsListWrapper\b[^>]*/>\n)',
        r'\g<1>\t\t<ChooserBar Value="0" />\n',
        content,
        count=1,
    )

    # 25. Add <VelocityDetail Value="0" /> after <Freeze> (present in Live 11, absent in Live 12)
    content = re.sub(
        r'^([ \t]*)(<Freeze\s+Value="[^"]*"\s*/>)',
        r'\1\2\n\1<VelocityDetail Value="0" />',
        content,
        flags=re.MULTILINE,
    )

    # 26. Add NextLocatorMapping / PreviousLocatorMapping after </Locators>
    # (present in Live 11, replaced by SetLocatorMapping in Live 12 which we stripped in step 17)
    _locator_mappings = (
        '\n\t\t\t<NextLocatorMapping>\n'
        '\t\t\t\t<PersistentKeyString Value="." />\n'
        '\t\t\t\t<IsNote Value="false" />\n'
        '\t\t\t\t<Channel Value="-1" />\n'
        '\t\t\t\t<NoteOrController Value="-1" />\n'
        '\t\t\t\t<LowerRangeNote Value="-1" />\n'
        '\t\t\t\t<UpperRangeNote Value="-1" />\n'
        '\t\t\t\t<ControllerMapMode Value="0" />\n'
        '\t\t\t</NextLocatorMapping>\n'
        '\t\t\t<PreviousLocatorMapping>\n'
        '\t\t\t\t<PersistentKeyString Value="," />\n'
        '\t\t\t\t<IsNote Value="false" />\n'
        '\t\t\t\t<Channel Value="-1" />\n'
        '\t\t\t\t<NoteOrController Value="-1" />\n'
        '\t\t\t\t<LowerRangeNote Value="-1" />\n'
        '\t\t\t\t<UpperRangeNote Value="-1" />\n'
        '\t\t\t\t<ControllerMapMode Value="0" />\n'
        '\t\t\t</PreviousLocatorMapping>'
    )
    content = content.replace('\t\t\t</Locators>', '\t\t\t</Locators>' + _locator_mappings, 1)

    # 27. Fix Live 12 → 11 stem-track downgrade Crash C (Pointee-namespace ID collision).
    #
    # Live 12 assigns small Pointee IDs (1–27) to MasterTrack/PreHearTrack mixer
    # AutomationTargets/ModulationTargets. In Live 11, AudioTrack IDs share the same
    # Pointee namespace. SHAD-style stem sessions number AudioTracks starting at Id=8
    # (one per track), so they collide with mixer-target IDs in MasterTrack and
    # PreHearTrack. Live 11's deserializer crashes silently on the wrong-typed lookup
    # (KERN_INVALID_ADDRESS, frames 2346044/2342340/...).
    #
    # BB11 native Live 11 sessions don't have this problem because their MasterTrack
    # AutomationTargets start at high IDs (5538+), placed after all AudioTracks.
    #
    # Fix: renumber MasterTrack AND PreHearTrack AT/MT IDs to a fresh high range
    # (max_id+100..), update any <PointeeId Value="N"/> references to match, and bump
    # <NextPointeeId> above the new max so Live 11's pointee allocator stays consistent.
    _target_tags = (
        'AutomationTarget',
        'ModulationTarget',
        'VolumeModulationTarget',
        'TranspositionModulationTarget',
        'GrainSizeModulationTarget',
        'FluxModulationTarget',
        'SampleOffsetModulationTarget',
    )
    # Use a fixed low starting ID (300) inside the safe zone that EDS leaves empty (33-483).
    # EDS's AutomationTargets start at 484; BB11 AudioTracks start at 104.
    # Using max_id+N would land in EDS's AT range (23000-30366) → different-type Pointee
    # collision on import → null virtual dispatch crash.
    _all_ids_set27 = set(int(m.group(1)) for m in re.finditer(r'\bId="(\d+)"', content))
    next_id = 300
    while next_id in _all_ids_set27:
        next_id += 1

    remap = {}
    target_re = re.compile(r'<(' + '|'.join(_target_tags) + r')\s+Id="(\d+)"')

    def _renumber(m):
        nonlocal next_id
        tag = m.group(1)
        old = int(m.group(2))
        if old < 30000 and old not in remap:
            remap[old] = next_id
            next_id += 1
            while next_id in _all_ids_set27:
                next_id += 1
        return f'<{tag} Id="{remap.get(old, old)}"'

    # Apply to MasterTrack block.
    mt_match = re.search(r'<MasterTrack\b.*?</MasterTrack>', content, flags=re.DOTALL)
    if mt_match:
        new_mt = target_re.sub(_renumber, mt_match.group(0))
        content = content[:mt_match.start()] + new_mt + content[mt_match.end():]

    # Apply to PreHearTrack block (re-search since indices shifted after MT replace).
    pht_match = re.search(r'<PreHearTrack\b.*?</PreHearTrack>', content, flags=re.DOTALL)
    if pht_match:
        new_pht = target_re.sub(_renumber, pht_match.group(0))
        content = content[:pht_match.start()] + new_pht + content[pht_match.end():]

    if remap:
        # Update <PointeeId Value="N"/> references where N was remapped.
        def _update_pointee(m):
            old = int(m.group(1))
            if old in remap:
                return f'<PointeeId Value="{remap[old]}"/>'
            return m.group(0)
        content = re.sub(r'<PointeeId\s+Value="(\d+)"\s*/>', _update_pointee, content)

        # Set <NextPointeeId> to true max+1 so Live 11's allocator stays consistent.
        _npi_ids_27 = [int(m.group(1)) for m in re.finditer(r'\bId="(\d+)"', content)]
        content = re.sub(
            r'(<NextPointeeId\s+Value=")\d+(")',
            f'\\g<1>{max(_npi_ids_27) + 1}\\g<2>',
            content,
            count=1,
        )

    # 28. Fix Live 12 → 11 stem-track downgrade Crash A (null warp marker array).
    #
    # Two related issues, requiring different fixes per track type:
    #
    # Issue A — MasterTrack / PreHearTrack:
    #   Live 12 populates their FreezeSequencer ClipSlotList with N empty <ClipSlot>
    #   entries. Live 11 iterates these on load and tries to access an unallocated
    #   WarpMarker array → null+8 atomic refcount crash (KERN_INVALID_ADDRESS at 0x8).
    #   Fix: replace with <ClipSlotList /> (these tracks have no parallel MainSequencer
    #   slot count to satisfy, so empty is safe).
    #
    # Issue B — AudioTrack / MidiTrack / GroupTrack / ReturnTrack (Freeze=false):
    #   Their FreezeSequencer ClipSlots carry NeedRefreeze="true". On any edit, Live 11
    #   walks the FreezeSequencer to evaluate which slots need refreezing. For empty
    #   slots with NeedRefreeze=true it tries to process the freeze, accessing null
    #   WarpMarker arrays → crash. Cannot use <ClipSlotList /> here — the FreezeSequencer
    #   slot count must match the MainSequencer slot count or Live 11 refuses to load
    #   ("Slot count mismatch"). Fix: keep slots, zero NeedRefreeze to false.
    #   Also zero NeedArrangerRefreeze on the track itself for the same reason.

    def _empty_freeze_clipslotlist(track_xml):
        """Replace <ClipSlotList>...</ClipSlotList> inside FreezeSequencer with empty tag."""
        fs_match = re.search(r'<FreezeSequencer\b.*?</FreezeSequencer>', track_xml, flags=re.DOTALL)
        if not fs_match:
            return track_xml
        new_fs = re.sub(
            r'<ClipSlotList>.*?</ClipSlotList>',
            '<ClipSlotList />',
            fs_match.group(0),
            flags=re.DOTALL,
        )
        return track_xml[:fs_match.start()] + new_fs + track_xml[fs_match.end():]

    def _clear_freeze_needrefreeze(track_xml):
        """Zero NeedRefreeze/HasStop inside FreezeSequencer ClipSlots and NeedArrangerRefreeze on track.

        NeedRefreeze="true": causes edit-crash (Live 11 tries to access null WarpMarker array
          when evaluating pending refreeze on empty slots).
        HasStop="true": causes timer-crash in LSong::CheckForClipOrSceneSelection() — Live 11
          tries to build a stop-clip object for the FreezeSequencer slot, which has a null
          back-reference in this context → null deref at 0x0.
        NeedArrangerRefreeze="true": same refreeze trigger at the track level.
        """
        fs_match = re.search(r'<FreezeSequencer\b.*?</FreezeSequencer>', track_xml, flags=re.DOTALL)
        if not fs_match:
            return track_xml
        new_fs = fs_match.group(0)
        new_fs = re.sub(r'<NeedRefreeze\s+Value="true"', '<NeedRefreeze Value="false"', new_fs)
        new_fs = re.sub(r'<HasStop\s+Value="true"', '<HasStop Value="false"', new_fs)
        result = track_xml[:fs_match.start()] + new_fs + track_xml[fs_match.end():]
        # Also zero NeedArrangerRefreeze on the track element itself.
        result = re.sub(
            r'<NeedArrangerRefreeze\s+Value="true"',
            '<NeedArrangerRefreeze Value="false"',
            result,
        )
        return result

    # MasterTrack and PreHearTrack: clear ClipSlotList entirely (cannot be frozen,
    # no MainSequencer slot count constraint).
    for track_tag in ('MasterTrack', 'PreHearTrack'):
        m = re.search(rf'<{track_tag}\b.*?</{track_tag}>', content, flags=re.DOTALL)
        if m:
            new_block = _empty_freeze_clipslotlist(m.group(0))
            content = content[:m.start()] + new_block + content[m.end():]

    # AudioTrack, MidiTrack, GroupTrack, ReturnTrack: for non-frozen tracks, zero
    # NeedRefreeze flags instead of clearing slots (slot count must stay intact).
    # Reverse iteration avoids index-shift after each replacement.
    for track_tag in ('AudioTrack', 'MidiTrack', 'GroupTrack', 'ReturnTrack'):
        matches = list(re.finditer(rf'<{track_tag}\b.*?</{track_tag}>', content, flags=re.DOTALL))
        for m in reversed(matches):
            track_xml = m.group(0)
            freeze_m = re.search(r'<Freeze\s+Value="(\w+)"', track_xml)
            if freeze_m and freeze_m.group(1).lower() == 'true':
                continue  # track is frozen — preserve its FreezeSequencer data
            new_block = _clear_freeze_needrefreeze(track_xml)
            content = content[:m.start()] + new_block + content[m.end():]

    # 29. Inject OriginalFileRef into AudioClips that lack it.
    #
    # Live 11 expects every AudioClip to carry an <OriginalFileRef> element (a FileRef
    # pointing to the original source file, identical to SampleRef/FileRef for non-
    # consolidated clips).  Sessions created natively in Live 12 omit this field.
    # When Live 11's CheckForClipOrSceneSelection() timer iterates clips and accesses
    # clip->originalFileRef, the null pointer causes KERN_INVALID_ADDRESS at 0x0.
    #
    # Fix: for each AudioClip that lacks <OriginalFileRef>, copy the SampleRef/FileRef
    # and inject it as <OriginalFileRef>, followed by the empty housekeeping elements
    # <BrowserContentPath> and <LocalFiltersJson> that Live 11 also expects nearby.

    def _inject_original_file_ref_into_clip(clip_xml):
        if '<OriginalFileRef>' in clip_xml:
            return clip_xml

        # Copy the FileRef from SampleRef to use as OriginalFileRef content.
        sr_match = re.search(r'<SampleRef>.*?(<FileRef\b.*?</FileRef>)', clip_xml, re.DOTALL)
        if sr_match:
            file_ref_content = sr_match.group(1)
        else:
            # No SampleRef/FileRef found; inject a minimal empty FileRef so Live 11
            # gets a non-null object to work with.
            file_ref_content = (
                '<FileRef>\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<RelativePathType Value="0" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<RelativePath Value="" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<Path Value="" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<Type Value="0" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<LivePackName Value="" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<LivePackId Value="" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<OriginalFileSize Value="0" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t<OriginalCrc Value="0" />\n'
                '\t\t\t\t\t\t\t\t\t\t\t</FileRef>'
            )

        # Detect indentation from the IsSongTempoMaster line (same level as our injection).
        indent_m = re.search(r'^(\t+)<IsSongTempoMaster', clip_xml, re.MULTILINE)
        indent = indent_m.group(1) if indent_m else '\t\t\t\t\t\t\t\t\t\t'

        injection = (
            f'\n{indent}<OriginalFileRef>\n'
            f'{indent}\t{file_ref_content}\n'
            f'{indent}</OriginalFileRef>\n'
            f'{indent}<BrowserContentPath Value="" />\n'
            f'{indent}<LocalFiltersJson Value="" />'
        )

        # Insert after the self-closing <IsSongTempoMaster .../> tag.
        iso_m = re.search(r'<IsSongTempoMaster\b[^>]*/>', clip_xml)
        if iso_m:
            pos = iso_m.end()
            return clip_xml[:pos] + injection + clip_xml[pos:]

        # Fallback: insert before </AudioClip>.
        end_pos = clip_xml.rfind('</AudioClip>')
        if end_pos != -1:
            return clip_xml[:end_pos] + injection + '\n' + clip_xml[end_pos:]

        return clip_xml

    # Apply in reverse order so string offsets stay valid.
    for m in reversed(list(re.finditer(r'<AudioClip\b.*?</AudioClip>', content, re.DOTALL))):
        patched = _inject_original_file_ref_into_clip(m.group(0))
        if patched is not m.group(0):
            content = content[:m.start()] + patched + content[m.end():]

    # 30. Renumber low-range AudioTrack/MidiTrack/GroupTrack IDs to avoid collision
    #     with Live 11 internal Pointee objects.
    #
    # Live 11 pre-allocates internal Pointee objects using IDs up to ~103 during
    # session initialization. Sessions downgraded from Live 12 have AudioTrack/
    # MidiTrack/GroupTrack IDs in the range 8-61 (one per track, assigned sequentially
    # at session creation). These collide with Live 11 internal objects, causing
    # CheckForClipOrSceneSelection() to crash at 0x0 (null virtual dispatch) ~4s
    # after load.
    #
    # Reference: BB11 (native Live 11, stable) has tracks starting at Id=104.
    # ReturnTrack IDs 2 and 3 are safe (Live 11 uses these IDs for return tracks
    # consistently — BB11 stable with ReturnTrack 2,3 confirms this).
    #
    # Fix: renumber AudioTrack/MidiTrack/GroupTrack Id attributes below 200 to a
    # fresh range above the current max Id. No PointeeId cross-references point to
    # these track IDs (confirmed by inspection — no TrackRef/TrackGroupId elements
    # reference them in these session types).

    _TRACK_SAFE_THRESHOLD = 200
    _track_tags = ('AudioTrack', 'MidiTrack', 'GroupTrack')

    # Start at 104: matches BB11 native start, above Live 11 internals (1-103),
    # and below EDS's first AutomationTarget at 484. Using max_id+N put tracks at
    # 23881+ which collided with EDS's AT range → different-type Pointee crash on import.
    _all_ids_s30 = set(int(m.group(1)) for m in re.finditer(r'\bId="(\d+)"', content))
    _next_safe = 104
    while _next_safe in _all_ids_s30:
        _next_safe += 1

    _track_id_remap = {}
    _track_open_re = re.compile(
        r'<(' + '|'.join(_track_tags) + r')\s+Id="(\d+)"'
    )
    for _m in _track_open_re.finditer(content):
        _old = int(_m.group(2))
        if _old < _TRACK_SAFE_THRESHOLD and _old not in _track_id_remap:
            _track_id_remap[_old] = _next_safe
            _next_safe += 1
            while _next_safe in _all_ids_s30:
                _next_safe += 1

    if _track_id_remap:
        def _remap_track_open_id(m):
            tag, old_s = m.group(1), m.group(2)
            old = int(old_s)
            return f'<{tag} Id="{_track_id_remap.get(old, old)}"'

        content = _track_open_re.sub(_remap_track_open_id, content)

        # Set NextPointeeId to true max+1 so Live 11's allocator stays consistent.
        _npi_ids_30 = [int(m.group(1)) for m in re.finditer(r'\bId="(\d+)"', content)]
        content = re.sub(
            r'(<NextPointeeId\s+Value=")\d+(")',
            f'\\g<1>{max(_npi_ids_30) + 1}\\g<2>',
            content,
            count=1,
        )

    # Write output
    dir_name  = os.path.dirname(path)
    base_name = os.path.basename(path)
    stem, ext = os.path.splitext(base_name)
    out_name  = stem + "_Live11" + ext
    out_path  = os.path.join(dir_name, out_name)

    try:
        with gzip.open(out_path, "wb") as f:
            f.write(content.encode("utf-8"))
    except Exception as e:
        return {"error": f"Could not write output file: {e}"}

    return {"ok": True, "new_path": out_path}


def _find_click_samples_dir():
    """Locate the directory containing CLASSIC-4TH'S.aif and CLASSIC-8TH'S.aif.

    Search order:
    1. sys._MEIPASS/_internal  (PyInstaller onedir runtime)
    2. Adjacent to this script (dev mode)
    3. App bundle Resources/click-samples  (relative to binary)
    """
    import os as _os
    import sys as _sys

    candidates = []

    # PyInstaller: _MEIPASS points to _internal dir
    if hasattr(_sys, '_MEIPASS'):
        candidates.append(_os.path.join(_sys._MEIPASS, 'click-samples'))

    # Adjacent to script / binary
    script_dir = _os.path.dirname(_os.path.abspath(__file__))
    candidates.append(_os.path.join(script_dir, 'click-samples'))

    # App bundle: binary lives at Contents/Resources/parse_als_dir/parse_als
    # Resources are at Contents/Resources/
    candidates.append(_os.path.join(script_dir, '..', '..', 'Resources', 'click-samples'))

    for d in candidates:
        d = _os.path.normpath(d)
        if _os.path.isfile(_os.path.join(d, "CLASSIC-4TH'S.aif")):
            return d

    raise FileNotFoundError(
        "click-samples directory not found. Checked: " + ", ".join(candidates)
    )


def _generate_click_track(output_path, bpm, time_sig, duration_seconds,
                          tempo_events=None, time_sig_events=None):
    """Generate a stereo PCM-16 click-track WAV from a tempo/time-sig map.

    tempo_events    – list of {beat, bpm} dicts (step changes; same-beat pair → single step)
    time_sig_events – list of {beat, numerator, denominator} dicts
    duration_seconds – total length of the output file

    Click pattern:
      Compound meters (6/8, 9/8, 12/8): eighth-note grid; first of every 3 eighths = accent,
      others = sub.
      All other meters: quarter beats = accent, upbeat eighths = sub.

    Gains: accent = 1.0, sub = 99/127. Uses L channel of CLASSIC-8TH'S.aif for both.
    Returns {"path": output_path} or {"error": "..."}.
    """
    import os as _os
    import math as _math
    import numpy as _np
    import soundfile as _sf

    try:
        samples_dir = _find_click_samples_dir()
    except FileNotFoundError as e:
        return {"error": str(e)}

    SR = 44100
    duration_seconds = float(duration_seconds)
    if duration_seconds <= 0:
        return {"error": "duration_seconds must be > 0"}

    # ── Load click samples ────────────────────────────────────────────────────
    # Accent: CLASSIC-4TH'S.aif (C4 in ALS template) — quarter-note click sound.
    # Sub:    CLASSIC-8TH'S.aif (C#4 in ALS template) — eighth-note click sound.
    # Gains normalized so accent ~0.665 (-3.5 dBFS) and sub ~0.512 (-5.8 dBFS),
    # matching the reference CLICK TRACK.wav peaks.
    def _load_mono_stereo(path):
        data, sr = _sf.read(path, dtype='float32', always_2d=True)
        # Pick the louder channel (L and R differ significantly in some AIF files)
        ch = 0 if _np.max(_np.abs(data[:, 0])) >= _np.max(_np.abs(data[:, 1])) else 1
        mono = data[:, ch:ch+1]
        return _np.hstack([mono, mono]), sr

    try:
        acc_raw, acc_sr = _load_mono_stereo(_os.path.join(samples_dir, "CLASSIC-4TH'S.aif"))
        sub_raw, sub_sr = _load_mono_stereo(_os.path.join(samples_dir, "CLASSIC-8TH'S.aif"))
    except Exception as e:
        return {"error": f"Failed to load click samples: {e}"}

    if acc_sr != SR or sub_sr != SR:
        return {"error": f"Click samples must be 44100 Hz (got acc={acc_sr}, sub={sub_sr})"}

    # Normalize each sample so its peak matches the reference output levels.
    TARGET_ACCENT = 0.665   # reference accent peak (-3.5 dBFS)
    TARGET_SUB    = 0.512   # reference sub peak    (-5.8 dBFS)

    acc_peak = float(_np.max(_np.abs(acc_raw))) or 1.0
    sub_peak = float(_np.max(_np.abs(sub_raw))) or 1.0

    accent_data = acc_raw
    sub_data    = sub_raw
    accent_gain = TARGET_ACCENT / acc_peak   # ~1.53 for 4TH'S (peak 0.434)
    sub_gain    = TARGET_SUB    / sub_peak   # ~0.777 for 8TH'S (peak 0.659)

    # ── Build tempo map: list of (beat_position, bpm) ────────────────────────
    if tempo_events:
        raw_evs = sorted(tempo_events, key=lambda e: e['beat'])
        # Deduplicate same-beat pairs (Ableton step-change = two events at same beat)
        deduped = {}
        for ev in raw_evs:
            deduped[round(ev['beat'], 6)] = float(ev['bpm'])
        tempo_map = sorted(deduped.items())  # [(beat, bpm), ...]
    else:
        tempo_map = []

    # ── Build time-sig map: list of (beat_position, numerator, denominator) ──
    if time_sig_events:
        ts_raw = sorted(time_sig_events, key=lambda e: e['beat'])
        ts_map = [(float(e['beat']), int(e['numerator']), int(e['denominator']))
                  for e in ts_raw]
    else:
        # Parse static time_sig string (e.g. "4/4", "6/8")
        parts = str(time_sig).split('/')
        num = int(parts[0]) if len(parts) == 2 else 4
        den = int(parts[1]) if len(parts) == 2 else 4
        ts_map = [(0.0, num, den)]

    def _ts_at_beat(beat):
        """Return (numerator, denominator) active at `beat`."""
        result = ts_map[0][1], ts_map[0][2]
        for b, n, d in ts_map:
            if b <= beat + 0.0001:
                result = n, d
            else:
                break
        return result

    def _bpm_at_beat(beat):
        """Return BPM active just before `beat`."""
        result = float(bpm)
        for b, v in tempo_map:
            if b <= beat + 0.0001:
                result = v
            else:
                break
        return result

    # ── Walk through beats and collect click events ───────────────────────────
    # click_events: list of (sample_frame, is_accent)
    click_events = []
    total_frames = int(duration_seconds * SR)

    beat = 0.0       # current position in quarter-note beats
    time_sec = 0.0   # session time in seconds at `beat`

    COMPOUND_DENOMS = {8, 16}  # compound: eighth/16th denominators when numerator % 3 == 0

    while time_sec < duration_seconds - 0.001:
        current_bpm  = _bpm_at_beat(beat)
        q_dur_sec    = 60.0 / current_bpm   # seconds per quarter-note beat
        num, den     = _ts_at_beat(beat)

        # Compound meter: num divisible by 3 with 8th/16th denominator
        is_compound = (den in COMPOUND_DENOMS) and (num % 3 == 0)

        if is_compound:
            # Each denominator unit is an eighth note = 0.5 quarter beats
            # Each denominator unit = (4/den) quarter beats
            eighth_dur_sec = q_dur_sec * 4.0 / den   # e.g. den=8 → 0.5*q_dur

            for eighth_idx in range(num):
                t = time_sec + eighth_idx * eighth_dur_sec
                if t >= duration_seconds:
                    break
                frame = int(t * SR)
                if frame >= total_frames:
                    break
                click_events.append((frame, eighth_idx % 3 == 0))

            bar_dur_sec   = num * eighth_dur_sec
            bar_dur_beats = num * (4.0 / den)   # denominator units in quarter-note beats
            beat     += bar_dur_beats
            time_sec += bar_dur_sec
        else:
            # Simple meter: one click per denominator unit; beat 0 = accent, rest = sub
            # Also place sub-clicks at the midpoint of each unit (eighth-note grid)
            unit_beats = 4.0 / den            # quarter-note beats per denominator unit
            unit_sec   = unit_beats * q_dur_sec

            for i in range(num):
                t_main = time_sec + i * unit_sec
                if t_main >= duration_seconds:
                    break
                frame = int(t_main * SR)
                if frame < total_frames:
                    click_events.append((frame, True))  # all quarter beats = accent

                # Sub-click at midpoint of each unit
                t_sub = t_main + unit_sec * 0.5
                if t_sub < duration_seconds:
                    frame_s = int(t_sub * SR)
                    if frame_s < total_frames:
                        click_events.append((frame_s, False))

            bar_dur_beats = num * unit_beats
            bar_dur_sec   = num * unit_sec
            beat     += bar_dur_beats
            time_sec += bar_dur_sec

    # ── Mix click events into output buffer ───────────────────────────────────
    out = _np.zeros((total_frames, 2), dtype=_np.float32)

    for frame, is_accent in click_events:
        sample_data = accent_data if is_accent else sub_data
        gain        = accent_gain if is_accent else sub_gain
        end = min(frame + len(sample_data), total_frames)
        length = end - frame
        if length <= 0:
            continue
        out[frame:end] += sample_data[:length] * gain

    # Hard-clip
    _np.clip(out, -1.0, 1.0, out=out)

    # ── Write WAV ─────────────────────────────────────────────────────────────
    try:
        _sf.write(output_path, out, SR, subtype='PCM_16')
    except Exception as e:
        return {"error": f"Failed to write click track WAV: {e}"}

    return {"path": output_path}


def _detect_key(wav_path):
    """Detect musical key using the Krumhansl-Schmuckler algorithm via librosa.

    Returns {"key": "Am", "raw": "A minor", "confidence": 0.847}
         or {"error": "..."}.
    """
    try:
        import librosa
        import numpy as np

        y, sr = librosa.load(wav_path, mono=True)
        # Separate harmonic content so percussion doesn't skew the chroma profile
        y_harmonic, _ = librosa.effects.hpss(y)

        chroma = librosa.feature.chroma_cqt(y=y_harmonic, sr=sr)
        chroma_mean = chroma.mean(axis=1)

        # Krumhansl-Schmuckler key profiles
        major_p = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
        minor_p = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
        notes   = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']

        best_corr, best_key = -np.inf, None
        for i, note in enumerate(notes):
            for mode, prof in [("major", major_p), ("minor", minor_p)]:
                corr = np.corrcoef(chroma_mean, np.roll(prof, i))[0, 1]
                if corr > best_corr:
                    best_corr, best_key = corr, f"{note} {mode}"

        # Map to MultiTracks approved keys (enharmonic equivalents for sharp-named outputs)
        key_map = {
            "C major": "C",    "C# major": "Db",  "D major": "D",    "D# major": "Eb",
            "E major": "E",    "F major": "F",    "F# major": "Gb",  "G major": "G",
            "G# major": "Ab",  "A major": "A",    "A# major": "Bb",  "B major": "B",
            "C minor": "Cm",   "C# minor": "C#m", "D minor": "Dm",   "D# minor": "Ebm",
            "E minor": "Em",   "F minor": "Fm",   "F# minor": "F#m", "G minor": "Gm",
            "G# minor": "G#m", "A minor": "Am",   "A# minor": "Bbm", "B minor": "Bm",
        }

        return {"key": key_map[best_key], "raw": best_key, "confidence": round(float(best_corr), 3)}
    except Exception as e:
        return {"error": str(e)}


def _ts_events_from_content(content):
    """Return a sorted list of (beat_pos, numerator, denominator) time-signature events
    parsed from raw decompressed .als XML bytes/string.  beat_pos is in Ableton
    quarter-note beats (NOT real time — the EnumEvent Time attribute is used directly).

    Uses the same regex approach as parse_time_signatures() so it is guaranteed to find
    the automation envelope that the Time Signatures panel already reads successfully.

    The ghost initial event (stored at a large negative beat like -63072000) is
    normalised to 0.0.  Falls back to the static Numerator/Denominator value if no
    automation envelope can be found (single unchanging time signature).
    """
    def decode_ts(value):
        num = (value % 99) + 1
        den = 2 ** (value // 99)
        return num, den

    if isinstance(content, bytes):
        content = content.decode("utf-8", errors="ignore")

    events = []
    for track_tag in ("MainTrack", "MasterTrack"):
        start = content.find(f"<{track_tag}")   # no ">" — handles <MainTrack Id="0">
        if start == -1:
            continue
        end = content.find(f"</{track_tag}>", start)
        if end == -1:
            continue
        track_content = content[start:end]

        ts_match = re.search(
            r'<TimeSignature>.*?<AutomationTarget Id="(\d+)"',
            track_content, re.DOTALL
        )
        if not ts_match:
            continue
        ts_target_id = ts_match.group(1)

        ae_match = re.search(
            r"<AutomationEnvelopes>(.*?)</AutomationEnvelopes>",
            track_content, re.DOTALL
        )
        if not ae_match:
            continue

        envelope_pattern  = r"<AutomationEnvelope[^>]*>(.*?)</AutomationEnvelope>"
        pointee_pattern   = r'<PointeeId\s+Value="(\d+)"'
        enum_event_pattern = r'<EnumEvent\s+[^>]*Time="([^"]+)"[^>]*Value="(\d+)"'

        for env_m in re.finditer(envelope_pattern, ae_match.group(1), re.DOTALL):
            env_xml = env_m.group(1)
            pid = re.search(pointee_pattern, env_xml)
            if not pid or pid.group(1) != ts_target_id:
                continue
            for ev in re.finditer(enum_event_pattern, env_xml):
                try:
                    beat = float(ev.group(1))
                    num, den = decode_ts(int(ev.group(2)))
                    # Ghost initial event is at a large negative beat — normalise to 0.
                    events.append((max(beat, 0.0), num, den))
                except (ValueError, TypeError):
                    pass
            break
        if events:
            break

    # Fallback: static Numerator/Denominator (session with no time sig automation).
    if not events:
        ts_num_m = re.search(r'<Numerator\s+Value="(\d+)"', content)
        ts_den_m = re.search(r'<Denominator\s+Value="(\d+)"', content)
        ts_num = int(ts_num_m.group(1)) if ts_num_m else 4
        ts_den = int(ts_den_m.group(1)) if ts_den_m else 4
        events.append((0.0, ts_num, ts_den))

    # Sort and deduplicate events at the same beat position (keep first).
    events.sort(key=lambda x: x[0])
    deduped = []
    for e in events:
        if deduped and abs(e[0] - deduped[-1][0]) < 0.001:
            continue
        deduped.append(e)
    return deduped


def _check_incomplete_bars(ts_events, calc_beat_time=None):
    """Check that each time-signature section between changes contains a whole
    number of bars.  Returns a list of warning strings for any incomplete sections.

    ts_events : list of (beat_pos, num, den) sorted ascending by beat_pos
                (quarter-note beats, as returned by _ts_events_from_content).
    calc_beat_time : optional callable(beat) → seconds used to format timecodes
                     in warnings; falls back to raw beat position if not provided.

    Only checks sections *between* consecutive time-signature changes.  The final
    section (last change → loop end) is already covered by the existing
    _is_on_barline(loop_end) check in validate_session.
    """
    TOL = 0.001
    warnings = []
    for i in range(len(ts_events) - 1):
        beat_start, num, den = ts_events[i]
        beat_end             = ts_events[i + 1][0]
        next_num, next_den   = ts_events[i + 1][1], ts_events[i + 1][2]
        section_beats        = beat_end - beat_start
        bar_beats            = num * (4.0 / den)
        bars                 = section_beats / bar_beats
        if abs(bars - round(bars)) > TOL:
            if calc_beat_time:
                try:
                    tc = fmt_time(calc_beat_time(beat_end))
                    loc = f"at {tc}"
                except Exception:
                    loc = f"at beat {beat_end:.3g}"
            else:
                loc = f"at beat {beat_end:.3g}"
            warnings.append(
                f"Incomplete bar: {num}/{den} section has {bars:.3g} bars "
                f"before {next_num}/{next_den} change {loc}"
            )
    return warnings


def _get_tempo_events(contents):
    """Return all tempo AutomationEvent entries as a list of (beat, value) tuples
    sorted by beat.  Falls back to [(0.0, manual_bpm)] for sessions with no
    tempo automation envelope (single static tempo).

    NOTE: In Ableton's XML the <Tempo> element (which holds the AutomationTarget
    Id) lives at the LiveSet level, NOT inside MainTrack/MasterTrack.  The actual
    AutomationEnvelope with the keyframe data IS inside MainTrack/MasterTrack.
    These must be looked up separately — searching for <Tempo> only within
    track_content will always fail.
    """
    if isinstance(contents, bytes):
        contents = contents.decode("utf-8", errors="ignore")

    # Step 1: find the Tempo AutomationTarget Id in the full document.
    tempo_target_match = re.search(
        r"<Tempo\b[^>]*>.*?<AutomationTarget\s+Id=\"(\d+)\"",
        contents, re.DOTALL
    )
    if not tempo_target_match:
        # No automation target — fall back to static Manual value.
        manual_m = re.search(r"<Tempo\b[^>]*>.*?<Manual\s+Value=\"([^\"]+)\"", contents, re.DOTALL)
        if manual_m:
            try:
                return [(0.0, float(manual_m.group(1)))]
            except (ValueError, TypeError):
                pass
        return []

    tempo_target_id = tempo_target_match.group(1)

    # Step 2: find the matching AutomationEnvelope inside MainTrack or MasterTrack.
    auto_event_pattern = r'<FloatEvent\s+[^>]*Time="([^"]+)"[^>]*Value="([^"]+)"'
    envelope_pattern   = r"<AutomationEnvelope[^>]*>(.*?)</AutomationEnvelope>"
    pointee_pattern    = r'<PointeeId\s+Value="(\d+)"'

    events = []
    found = False

    for track_tag in ("MainTrack", "MasterTrack"):
        start = contents.find(f"<{track_tag}")
        if start == -1:
            continue
        end = contents.find(f"</{track_tag}>", start)
        if end == -1:
            continue
        track_content = contents[start:end]

        ae_match = re.search(
            r"<AutomationEnvelopes>(.*?)</AutomationEnvelopes>",
            track_content, re.DOTALL
        )
        if not ae_match:
            continue

        for env_m in re.finditer(envelope_pattern, ae_match.group(1), re.DOTALL):
            env_xml = env_m.group(1)
            pid = re.search(pointee_pattern, env_xml)
            if not pid or pid.group(1) != tempo_target_id:
                continue
            for ev_m in re.finditer(auto_event_pattern, env_xml):
                try:
                    events.append((float(ev_m.group(1)), float(ev_m.group(2))))
                except (ValueError, TypeError):
                    pass
            found = True
            break

        if found:
            break

    if not found:
        # Envelope not found in track — fall back to static Manual value.
        manual_m = re.search(r"<Tempo\b[^>]*>.*?<Manual\s+Value=\"([^\"]+)\"", contents, re.DOTALL)
        if manual_m:
            try:
                events.append((0.0, float(manual_m.group(1))))
            except (ValueError, TypeError):
                pass

    return sorted(events, key=lambda x: x[0])



def _check_tempo_ramps(contents):
    """Return warning strings for any tempo automation segment that uses a ramp
    or curve rather than an instantaneous step change.

    In Ableton, a step change is stored as two consecutive events at the same
    (or nearly the same) beat position — one holding the old value, the next
    jumping to the new value.  A ramp is any pair of consecutive events where
    the BPM value differs AND the beat positions are non-trivially different
    (delta > 0.01 quarter-note beats).  Both linear ramps and bezier curves
    are caught.  The phantom initial event (beat < 0) is excluded.
    """
    events = _get_tempo_events(contents)
    # Filter out the phantom event at beat ~-63072000
    real = [(b, v) for b, v in events if b >= 0]

    STEP_TOL = 0.01   # beats — pairs closer than this are treated as a step
    VAL_TOL  = 0.001  # BPM  — ignore float noise between identical values

    warnings = []
    for i in range(len(real) - 1):
        b0, v0 = real[i]
        b1, v1 = real[i + 1]
        if abs(v1 - v0) > VAL_TOL and (b1 - b0) > STEP_TOL:
            warnings.append(
                f"Tempo ramp: {v0:.6g} -> {v1:.6g} BPM "
                "— use step changes (staircase) instead of ramps or curves"
            )
    return warnings


def _is_on_barline(beat_pos, ts_events):
    """Return True if beat_pos (Ableton quarter-note beats) falls exactly on a bar
    boundary, respecting every time-signature change in ts_events.

    Ableton guarantees time-signature changes only occur on bar boundaries, so each
    section's start beat is itself a barline.  We only need to check whether the
    offset within the current section is an exact multiple of that section's bar length.
    """
    TOLS = 0.001
    for i, (ts_beat, num, den) in enumerate(ts_events):
        next_ts_beat = ts_events[i + 1][0] if i + 1 < len(ts_events) else float("inf")
        if beat_pos > next_ts_beat + TOLS:
            continue  # beat_pos lies in a later section
        offset = beat_pos - ts_beat
        if offset < -TOLS:
            return False  # before the arrangement start
        bpb = num * (4.0 / den)
        bar_frac = offset / bpb
        return abs(bar_frac - round(bar_frac)) < TOLS
    return False


def validate_session(path):
    """Validate loop bracket vs audio clip alignment.

    Opens the .als as gzipped XML independently of dawtool.
    Returns a dict with 'warnings' (list of strings) and 'session_info'.
    """
    import gzip
    import xml.etree.ElementTree as ET

    warnings = []
    info = {
        "loop_start": None,
        "loop_end": None,
        "clip_name": None,
        "clip_start": None,
        "clip_end": None,
    }

    try:
        with gzip.open(path, "rb") as f:
            raw_xml = f.read()
        import io
        root = ET.parse(io.BytesIO(raw_xml)).getroot()
    except Exception:
        return {"warnings": ["Could not read session XML for validation"], "session_info": info}

    # ── Transport loop bracket ──
    transport_start_el = root.find(".//Transport/LoopStart")
    transport_length_el = root.find(".//Transport/LoopLength")
    if transport_start_el is not None and transport_length_el is not None:
        loop_start = float(transport_start_el.get("Value", "0"))
        loop_length = float(transport_length_el.get("Value", "0"))
        loop_end = loop_start + loop_length
        info["loop_start"] = loop_start
        info["loop_end"] = loop_end
    else:
        warnings.append("No arrangement loop bracket found")
        return {"warnings": warnings, "session_info": info}

    # ── Time signature events (for barline checks) ──
    # Uses the same regex approach as parse_time_signatures() — proven to find the
    # automation envelope correctly — so barline checks respect every time sig change.
    ts_events = _ts_events_from_content(raw_xml)

    # ── BPM (for length tolerance) ──
    # 1ms tolerance in beats = bpm / 60000.0
    _bpm_m = re.search(rb"<Tempo\b[^>]*>.*?<Manual\s+Value=\"([^\"]+)\"", raw_xml, re.DOTALL)
    _bpm = float(_bpm_m.group(1)) if _bpm_m else 120.0
    _length_tol = _bpm / 12000.0  # 5ms expressed in beats

    # ── Tempo checks (independent of clips — run before any clip-related early returns) ──
    # 4. Tempo ramps — all changes must be step changes, not linear/curved ramps
    warnings.extend(_check_tempo_ramps(raw_xml))

    # ── Audio clips (arrangement only — skip freeze clips) ──
    clips = []
    for clip in root.iter("AudioClip"):
        name = clip.find("Name")
        cname = name.get("Value", "") if name is not None else ""
        # Skip freeze clips (Ableton-internal)
        if "(Freeze)" in cname:
            continue
        cs = clip.find("CurrentStart")
        ce = clip.find("CurrentEnd")
        if cs is not None and ce is not None:
            clips.append({
                "name": cname,
                "start": float(cs.get("Value", "0")),
                "end": float(ce.get("Value", "0")),
            })

    if len(clips) == 0:
        warnings.append("No audio clips found in session")
        return {"warnings": warnings, "session_info": info}

    # Use the first non-freeze clip as the reference
    ref_clip = clips[0]
    info["clip_name"] = ref_clip["name"]
    info["clip_start"] = ref_clip["start"]
    info["clip_end"] = ref_clip["end"]

    # ── Validation checks ──

    # 1. Loop bracket ends on beat 1 of a measure
    if not _is_on_barline(loop_end, ts_events):
        warnings.append("Loop bracket does not end on beat 1")

    # 2. Clip ends on beat 1 of a measure
    if not _is_on_barline(ref_clip["end"], ts_events):
        warnings.append(
            f"\"{ref_clip['name']}\" does not end on beat 1"
        )

    # 3. Loop bracket and clip must match (1ms tolerance)
    diff = abs(ref_clip["end"] - loop_end)
    if diff > _length_tol:
        warnings.append(
            f"Loop bracket and \"{ref_clip['name']}\" are not the same length"
        )

    return {"warnings": warnings, "session_info": info}


def parse_file(path):
    """Parse a single .als file and return a JSON string."""
    try:
        from dawtool import load_project

        with open(path, "rb") as fh:
            proj = load_project(path, fh, theoretical=False)
            proj.parse()

        locator_data = _extract_locator_data(path)  # list of (id, beat, name_raw)
        markers = [
            {"time": fmt_time(m.time),
             "time_end": "",  # filled in below
             # Use the raw name from XML so leading/trailing spaces are preserved
             # (dawtool strips them, which would hide extra-space locator errors).
             "text": locator_data[i][2] if i < len(locator_data) else m.text,
             "als_id": locator_data[i][0] if i < len(locator_data) else "",
             "beat": locator_data[i][1] if i < len(locator_data) else 0.0,
             "off_beat": False}  # updated below after ts_events are computed
            for i, m in enumerate(proj.markers)
        ]
        time_sigs = parse_time_signatures(proj)

        # BPM from the project's initial tempo (before any automation)
        bpm = None
        if proj.beats_per_min is not None:
            bpm = round(proj.beats_per_min, 2)

        # Session validation (loop bracket vs clip alignment)
        validation = validate_session(path)

        # Incomplete-bar check: every section between time-signature changes must
        # contain a whole number of bars for the previous signature.
        try:
            ts_beat_events = _ts_events_from_content(proj.contents)
            incomplete = _check_incomplete_bars(ts_beat_events, proj._calc_beat_real_time)
            validation["warnings"].extend(incomplete)
            # Off-beat locator check: every locator should land on beat 1 of a bar.
            for i in range(len(markers)):
                if i < len(locator_data):
                    beat = locator_data[i][1]
                    markers[i]["off_beat"] = not _is_on_barline(beat, ts_beat_events)
        except Exception:
            pass

        # Expected stem duration: loop bracket length converted to real seconds.
        # Uses dawtool's tempo-aware beat→time conversion so tempo-automated
        # sessions are handled correctly. Tolerance at compare time is 1 sample
        # (1/sampleRate) to absorb floating-point rounding — effectively 0ms.
        expected_duration = None
        loop_end_time_str = None
        loop_end_secs = None
        try:
            loop_start = validation["session_info"]["loop_start"]
            loop_end   = validation["session_info"]["loop_end"]
            if loop_start is not None and loop_end is not None:
                t_start = proj._calc_beat_real_time(loop_start)
                t_end   = proj._calc_beat_real_time(loop_end)
                expected_duration = round(t_end - t_start, 6)
                loop_end_time_str = fmt_time(t_end)
                loop_end_secs = t_end
        except Exception:
            pass

        # Fill time_end for each marker:
        #   - all but the last: TIME END = next marker's TIME START
        #   - last marker:      TIME END = loop bracket end, unless the last
        #                       locator is "NEXT SONG" (medley placeholder placed
        #                       after the loop bracket) — in that case leave blank
        for i in range(len(markers)):
            if i + 1 < len(markers):
                markers[i]["time_end"] = markers[i + 1]["time"]
            else:
                is_next_song = markers[i]["text"].strip().upper() == "NEXT SONG"
                markers[i]["time_end"] = "" if is_next_song else (loop_end_time_str or "")

        # Index of the first marker at or after the first real tempo change.
        # tempo_automation_events[0] is always a phantom event at beat -63072000
        # (Ableton's default-tempo sentinel); real changes start at index 1+.
        first_tempo_change_marker_index = None
        try:
            if proj.has_tempo_automation:
                real_changes = [e for e in proj.tempo_automation_events if e.beat >= 0]
                if real_changes:
                    change_time = proj._calc_beat_real_time(real_changes[0].beat)
                    for i, m in enumerate(proj.markers):
                        if m.time >= change_time:
                            first_tempo_change_marker_index = i
                            break
        except Exception:
            pass

        # Major Live version (e.g. 11 or 12) for the UI to conditionally show
        # version-specific actions such as "Convert to Live 11".
        live_major_version = None
        try:
            live_major_version = proj.version.minorA
        except Exception:
            pass
        if live_major_version is None:
            try:
                import gzip as _gz
                with _gz.open(path, "rb") as _f:
                    _hdr = _f.read(256).decode("utf-8", errors="ignore")
                _vm = re.search(r'MinorVersion="(\d+)\.', _hdr)
                if _vm:
                    live_major_version = int(_vm.group(1))
            except Exception:
                pass

        # Tempo automation events for metronome beat scheduling in Swift.
        # The phantom sentinel (beat < 0) is Ableton's initial BPM anchor. Filter it out,
        # but if no real event exists at beat 0, inject one so Swift's beatToTime() has
        # the correct origin BPM (without it every beat maps to a large negative time).
        try:
            raw_tempo_events = _get_tempo_events(proj.contents)
            phantom_events = [(b, v) for b, v in raw_tempo_events if b < 0]
            real_events = [[b, v] for b, v in raw_tempo_events if b >= 0]
            if phantom_events and (not real_events or real_events[0][0] > 0):
                real_events.insert(0, [0.0, phantom_events[-1][1]])
            tempo_events = real_events
        except Exception:
            tempo_events = []

        # Compute timecodes for each tempo event using beat-to-seconds arithmetic.
        # We do this ourselves (not via proj._calc_beat_real_time) because we bypass
        # dawtool's tempo parsing for correctness on sessions with FloatEvent automation.
        _te_times = []
        _running = 0.0
        for _i, (_b, _bpm) in enumerate(tempo_events):
            if _i == 0:
                _te_times.append(0.0)
            else:
                _prev_b, _prev_bpm = tempo_events[_i - 1]
                _running += (_b - _prev_b) * 60.0 / _prev_bpm
                _te_times.append(_running)

        # Identify ramp pairs (same logic as _check_tempo_ramps)
        _STEP_TOL = 0.01
        _VAL_TOL = 1e-6
        _ramp_starts = set()
        _ramp_ends = set()
        for _i in range(len(tempo_events) - 1):
            _b0, _v0 = tempo_events[_i]
            _b1, _v1 = tempo_events[_i + 1]
            if abs(_v1 - _v0) > _VAL_TOL and (_b1 - _b0) > _STEP_TOL:
                _ramp_starts.add(_i)
                _ramp_ends.add(_i + 1)

        return json.dumps({
            "error": None,
            "file": os.path.basename(path),
            "live_major_version": live_major_version,
            "bpm": bpm,
            "markers": markers,
            "time_signatures": [
                {"time": fmt_time(t), "sig": f"{n}/{d}", "beat": b}
                for t, n, d, b in time_sigs
            ],
            "warnings": validation["warnings"],
            "session_info": validation["session_info"],
            "expected_duration": expected_duration,
            "first_tempo_change_marker_index": first_tempo_change_marker_index,
            "tempo_events": [
                {"time": fmt_time(_te_times[i]), "bpm": v, "beat": b,
                 "is_ramp_start": i in _ramp_starts, "is_ramp_end": i in _ramp_ends}
                for i, (b, v) in enumerate(tempo_events)
            ],
        })

    except FileNotFoundError:
        return json.dumps({"error": f"File not found: {path}", "markers": [], "time_signatures": [], "file": "", "bpm": None, "warnings": []})
    except Exception as e:
        return json.dumps({"error": str(e), "markers": [], "time_signatures": [], "file": "", "bpm": None, "warnings": []})


def _generate_als(output_path, clips, bpm, tempo_events, time_signatures, locators, loop_end_beat):
    """Generate a minimal Live 11 .als from scratch and write to output_path.

    clips          – list of {name, file_path, duration_seconds, volume_db}
    bpm            – initial BPM (float) at beat 0
    tempo_events   – list of {beat, bpm} for additional tempo changes
    time_signatures– list of {beat, numerator, denominator}
    locators       – list of {beat, name}
    loop_end_beat  – loop bracket end in quarter-note beats
    """
    import math as _math

    # ── helpers ──────────────────────────────────────────────────────────────
    _idc = [20]  # IDs 1–20 reserved for master track; audio tracks use 21+
    def _nid(): _idc[0] += 1; return _idc[0]

    def encode_ts(num, den):
        return (num - 1) + int(_math.log2(den)) * 99

    def db_to_amp(db):
        return 10.0 ** (db / 20.0)

    def warp_sec(beat_bpm):
        return repr(1.875 / beat_bpm)

    # ── initial values ────────────────────────────────────────────────────────
    initial_num = time_signatures[0]['numerator']  if time_signatures else 4
    initial_den = time_signatures[0]['denominator'] if time_signatures else 4
    initial_ts_val = encode_ts(initial_num, initial_den)

    # ── tempo FloatEvents ─────────────────────────────────────────────────────
    # Ghost event at negative beat + real events. Step changes = two events at same beat.
    all_tempo_evs = [(0.0, bpm)]
    for ev in sorted(tempo_events, key=lambda x: x['beat']):
        prev_bpm = all_tempo_evs[-1][1]
        all_tempo_evs.append((ev['beat'], prev_bpm))   # pre-step (old value)
        all_tempo_evs.append((ev['beat'], ev['bpm']))  # post-step (new value)

    # Ghost event at -63072000, then real events (step changes = two events at same beat)
    tempo_float_lines = [f'								<FloatEvent Id="0" Time="-63072000" Value="{repr(bpm)}" />']
    for ev_id, (b, v) in enumerate(all_tempo_evs[1:], 1):
        tempo_float_lines.append(f'								<FloatEvent Id="{ev_id}" Time="{repr(b)}" Value="{repr(v)}" />')
    tempo_float_events = '\n'.join(tempo_float_lines)

    # ── time sig EnumEvents ───────────────────────────────────────────────────
    ts_enum_lines = [f'								<EnumEvent Id="0" Time="-63072000" Value="{initial_ts_val}" />']
    for i, ts in enumerate(sorted(time_signatures, key=lambda x: x['beat']), 1):
        val = encode_ts(ts['numerator'], ts['denominator'])
        ts_beat = repr(float(ts['beat']))
        ts_enum_lines.append(f'								<EnumEvent Id="{i}" Time="{ts_beat}" Value="{val}" />')
    ts_enum_events = '\n'.join(ts_enum_lines)

    # ── freeze sequencer helper ───────────────────────────────────────────────
    def freeze_seq(on_id, pointee_id):
        slots = '\n'.join(f'''					<ClipSlot Id="{i}">
						<LomId Value="0" />
						<ClipSlot><Value /></ClipSlot>
						<HasStop Value="true" />
						<NeedRefreeze Value="true" />
					</ClipSlot>''' for i in range(8))
        return f'''				<FreezeSequencer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{on_id}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="{pointee_id}" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="true" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<ClipSlotList>
{slots}
					</ClipSlotList>
					<MonitoringEnum Value="1" />
					<Sample><ArrangerAutomation><Events /></ArrangerAutomation></Sample>
					<VolumeModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></VolumeModulationTarget>
					<TranspositionModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></TranspositionModulationTarget>
					<GrainSizeModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></GrainSizeModulationTarget>
					<FluxModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></FluxModulationTarget>
					<SampleOffsetModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></SampleOffsetModulationTarget>
					<Recorder><IsArmed Value="false" /><TakeCounter Value="1" /></Recorder>
				</FreezeSequencer>'''

    # ── per-clip routing snippet ──────────────────────────────────────────────
    def routing_block(upper_in, lower_in, upper_out="Master", lower_out=""):
        return f'''					<AudioInputRouting>
						<Target Value="AudioIn/External/M0" />
						<UpperDisplayString Value="{upper_in}" />
						<LowerDisplayString Value="{lower_in}" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</AudioInputRouting>
					<MidiInputRouting>
						<Target Value="MidiIn/External.All/-1" />
						<UpperDisplayString Value="Ext: All Ins" />
						<LowerDisplayString Value="" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</MidiInputRouting>
					<AudioOutputRouting>
						<Target Value="AudioOut/Master" />
						<UpperDisplayString Value="{upper_out}" />
						<LowerDisplayString Value="{lower_out}" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</AudioOutputRouting>
					<MidiOutputRouting>
						<Target Value="MidiOut/None" />
						<UpperDisplayString Value="None" />
						<LowerDisplayString Value="" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</MidiOutputRouting>'''

    # ── audio track builder ───────────────────────────────────────────────────
    def audio_track(track_id, clip_idx, clip):
        amp = db_to_amp(clip.get('volume_db', 0.0))
        dur_sec = clip['duration_seconds']
        name = clip['name']
        fpath = clip['file_path']
        warp2 = warp_sec(bpm)

        on_id     = _nid()
        send0_at  = _nid(); send0_mt = _nid()
        send1_at  = _nid(); send1_mt = _nid()
        spk_id    = _nid()
        pan_at    = _nid(); pan_mt = _nid()
        spl_l_at  = _nid(); spl_l_mt = _nid()
        spl_r_at  = _nid(); spl_r_mt = _nid()
        vol_at    = _nid(); vol_mt = _nid()
        xfade_at  = _nid()
        pointee_id = _nid()
        clip_at   = _nid()
        frz_on    = _nid(); frz_pt = _nid()

        sends = f'''						<TrackSendHolder Id="0">
							<Send>
								<LomId Value="0" /><Manual Value="0.0003162277571" />
								<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1" /></MidiControllerRange>
								<AutomationTarget Id="{send0_at}"><LockEnvelope Value="0" /></AutomationTarget>
								<ModulationTarget Id="{send0_mt}"><LockEnvelope Value="0" /></ModulationTarget>
							</Send>
							<Active Value="true" />
						</TrackSendHolder>
						<TrackSendHolder Id="1">
							<Send>
								<LomId Value="0" /><Manual Value="0.0003162277571" />
								<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1" /></MidiControllerRange>
								<AutomationTarget Id="{send1_at}"><LockEnvelope Value="0" /></AutomationTarget>
								<ModulationTarget Id="{send1_mt}"><LockEnvelope Value="0" /></ModulationTarget>
							</Send>
							<Active Value="true" />
						</TrackSendHolder>'''

        return f'''		<AudioTrack Id="{track_id}">
			<LomId Value="0" /><LomIdView Value="0" />
			<IsContentSelectedInDocument Value="false" /><PreferredContentViewMode Value="0" />
			<TrackDelay><Value Value="0" /><IsValueSampleBased Value="false" /></TrackDelay>
			<Name>
				<EffectiveName Value="{name}" /><UserName Value="{name}" />
				<Annotation Value="" /><MemorizedFirstClipName Value="{name}" />
			</Name>
			<Color Value="0" />
			<AutomationEnvelopes><Envelopes /></AutomationEnvelopes>
			<TrackGroupId Value="-1" /><TrackUnfolded Value="true" />
			<DevicesListWrapper LomId="0" /><ClipSlotsListWrapper LomId="0" />
			<ViewData Value="{{}}" />
			<TakeLanes><TakeLanes /><AreTakeLanesFolded Value="true" /></TakeLanes>
			<LinkedTrackGroupId Value="-1" />
			<SavedPlayingSlot Value="-1" /><SavedPlayingOffset Value="0" />
			<Freeze Value="false" /><VelocityDetail Value="0" />
			<NeedArrangerRefreeze Value="true" /><PostProcessFreezeClips Value="0" />
			<DeviceChain>
				<AutomationLanes>
					<AutomationLanes>
						<AutomationLane Id="0">
							<SelectedDevice Value="1" /><SelectedEnvelope Value="0" />
							<IsContentSelectedInDocument Value="false" /><LaneHeight Value="68" />
						</AutomationLane>
					</AutomationLanes>
					<AreAdditionalAutomationLanesFolded Value="false" />
				</AutomationLanes>
				<ClipEnvelopeChooserViewState>
					<SelectedDevice Value="1" /><SelectedEnvelope Value="0" /><PreferModulationVisible Value="true" />
				</ClipEnvelopeChooserViewState>
{routing_block("Ext. In", "1")}
				<Mixer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{on_id}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="{pointee_id}" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<Sends>
{sends}
					</Sends>
					<Speaker>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{spk_id}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</Speaker>
					<SoloSink Value="false" /><PanMode Value="0" />
					<Pan>
						<LomId Value="0" /><Manual Value="0" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{pan_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{pan_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</Pan>
					<SplitStereoPanL>
						<LomId Value="0" /><Manual Value="-1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{spl_l_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{spl_l_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanL>
					<SplitStereoPanR>
						<LomId Value="0" /><Manual Value="1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{spl_r_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{spl_r_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanR>
					<Volume>
						<LomId Value="0" /><Manual Value="{repr(amp)}" />
						<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1.99526231" /></MidiControllerRange>
						<AutomationTarget Id="{vol_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{vol_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</Volume>
					<ViewStateSesstionTrackWidth Value="93" />
					<CrossFadeState><LomId Value="0" /><Manual Value="1" /><AutomationTarget Id="{xfade_at}"><LockEnvelope Value="0" /></AutomationTarget></CrossFadeState><SendsListWrapper LomId="0" />
				</Mixer>
				<MainSequencer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{clip_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="{_nid()}" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<ClipSlotList>
						<ClipSlot Id="0"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="1"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="2"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="3"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="4"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="5"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="6"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
						<ClipSlot Id="7"><LomId Value="0" /><ClipSlot><Value /></ClipSlot><HasStop Value="true" /><NeedRefreeze Value="true" /></ClipSlot>
					</ClipSlotList>
					<MonitoringEnum Value="2" />
					<Sample>
						<ArrangerAutomation>
							<Events>
								<AudioClip Id="{clip_idx}" Time="0">
									<LomId Value="0" /><LomIdView Value="0" />
									<CurrentStart Value="0" /><CurrentEnd Value="{repr(float(loop_end_beat))}" />
									<Loop>
										<LoopStart Value="0" /><LoopEnd Value="{repr(dur_sec)}" />
										<StartRelative Value="0" /><LoopOn Value="false" />
										<OutMarker Value="{repr(dur_sec)}" />
										<HiddenLoopStart Value="0" /><HiddenLoopEnd Value="{repr(dur_sec)}" />
									</Loop>
									<Name Value="{name}" /><Annotation Value="" /><Color Value="0" />
									<LaunchMode Value="0" /><LaunchQuantisation Value="0" />
									<TimeSignature>
										<TimeSignatures>
											<RemoteableTimeSignature Id="0">
												<Numerator Value="{initial_num}" />
												<Denominator Value="{initial_den}" />
												<Time Value="0" />
											</RemoteableTimeSignature>
										</TimeSignatures>
									</TimeSignature>
									<Envelopes><Envelopes /></Envelopes>
									<ScrollerTimePreserver><LeftTime Value="0" /><RightTime Value="0" /></ScrollerTimePreserver>
									<TimeSelection><AnchorTime Value="0" /><OtherTime Value="0" /></TimeSelection>
									<Legato Value="false" /><Ram Value="false" />
									<GrooveSettings><GrooveId Value="-1" /></GrooveSettings>
									<Disabled Value="false" /><VelocityAmount Value="0" />
									<FollowAction>
										<FollowTime Value="4" /><IsLinked Value="true" /><LoopIterations Value="1" />
										<FollowActionA Value="4" /><FollowActionB Value="0" />
										<FollowChanceA Value="100" /><FollowChanceB Value="0" />
										<JumpIndexA Value="1" /><JumpIndexB Value="1" />
										<FollowActionEnabled Value="false" />
									</FollowAction>
									<Grid>
										<FixedNumerator Value="1" /><FixedDenominator Value="16" />
										<GridIntervalPixel Value="20" /><Ntoles Value="2" />
										<SnapToGrid Value="true" /><Fixed Value="false" />
									</Grid>
									<FreezeStart Value="0" /><FreezeEnd Value="0" />
									<IsWarped Value="false" />
									<TakeId Value="1" />
									<SampleRef>
										<FileRef>
											<RelativePathType Value="1" />
											<RelativePath Value="" />
											<Path Value="{fpath}" />
											<Type Value="2" />
											<LivePackName Value="" /><LivePackId Value="" />
											<OriginalFileSize Value="0" /><OriginalCrc Value="0" />
										</FileRef>
										<LastModDate Value="0" />
										<SourceContext />
										<SampleUsageHint Value="0" />
										<DefaultDuration Value="0" />
										<DefaultSampleRate Value="44100" />
									</SampleRef>
									<Onsets><UserOnsets /><HasUserOnsets Value="false" /></Onsets>
									<WarpMode Value="4" />
									<GranularityTones Value="30" /><GranularityTexture Value="65" />
									<FluctuationTexture Value="25" /><TransientResolution Value="6" />
									<TransientLoopMode Value="2" /><TransientEnvelope Value="100" />
									<ComplexProFormants Value="100" /><ComplexProEnvelope Value="128" />
									<Sync Value="true" /><HiQ Value="true" /><Fade Value="false" />
									<Fades>
										<FadeInLength Value="0" /><FadeOutLength Value="0" />
										<ClipFadesAreInitialized Value="true" /><CrossfadeInState Value="0" />
										<FadeInCurveSkew Value="0" /><FadeInCurveSlope Value="0" />
										<FadeOutCurveSkew Value="0" /><FadeOutCurveSlope Value="0" />
										<IsDefaultFadeIn Value="false" /><IsDefaultFadeOut Value="false" />
									</Fades>
									<PitchCoarse Value="0" /><PitchFine Value="0" />
									<SampleVolume Value="1" />
									<WarpMarkers>
										<WarpMarker Id="0" SecTime="0" BeatTime="0" />
										<WarpMarker Id="1" SecTime="{warp2}" BeatTime="0.03125" />
									</WarpMarkers>
									<SavedWarpMarkersForStretched />
									<MarkersGenerated Value="true" />
									<IsSongTempoMaster Value="false" />
								</AudioClip>
							</Events>
							<AutomationTransformViewState>
								<IsTransformPending Value="false" /><TimeAndValueTransforms />
							</AutomationTransformViewState>
						</ArrangerAutomation>
					</Sample>
					<VolumeModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></VolumeModulationTarget>
					<TranspositionModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></TranspositionModulationTarget>
					<GrainSizeModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></GrainSizeModulationTarget>
					<FluxModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></FluxModulationTarget>
					<SampleOffsetModulationTarget Id="{_nid()}"><LockEnvelope Value="0" /></SampleOffsetModulationTarget>
					<PitchViewScrollPosition Value="-1073741824" />
					<SampleOffsetModulationScrollPosition Value="-1073741824" />
					<Recorder><IsArmed Value="false" /><TakeCounter Value="1" /></Recorder>
				</MainSequencer>
{freeze_seq(frz_on, frz_pt)}
				<DeviceChain>
					<Devices />
					<SignalModulations />
				</DeviceChain>
			</DeviceChain>
		</AudioTrack>'''

    # ── return track builder ──────────────────────────────────────────────────
    def return_track(track_id, label):
        on_id = _nid(); spk_id = _nid()
        pan_at = _nid(); pan_mt = _nid()
        spl_l_at = _nid(); spl_l_mt = _nid()
        spl_r_at = _nid(); spl_r_mt = _nid()
        vol_at = _nid(); vol_mt = _nid()
        xfade_at = _nid()
        pointee_id = _nid()
        send0_at = _nid(); send0_mt = _nid()
        send1_at = _nid(); send1_mt = _nid()
        frz_on = _nid(); frz_pt = _nid()
        frz_vol_mt = _nid(); frz_trans_mt = _nid(); frz_grain_mt = _nid()
        frz_flux_mt = _nid(); frz_soff_mt = _nid()
        return f'''		<ReturnTrack Id="{track_id}">
			<LomId Value="0" /><LomIdView Value="0" />
			<IsContentSelectedInDocument Value="false" /><PreferredContentViewMode Value="0" />
			<TrackDelay><Value Value="0" /><IsValueSampleBased Value="false" /></TrackDelay>
			<Name>
				<EffectiveName Value="{label}" /><UserName Value="" />
				<Annotation Value="" /><MemorizedFirstClipName Value="" />
			</Name>
			<Color Value="1" />
			<AutomationEnvelopes><Envelopes /></AutomationEnvelopes>
			<TrackGroupId Value="-1" /><TrackUnfolded Value="false" />
			<DevicesListWrapper LomId="0" /><ClipSlotsListWrapper LomId="0" />
			<ViewData Value="{{}}" />
			<TakeLanes><TakeLanes /><AreTakeLanesFolded Value="true" /></TakeLanes>
			<LinkedTrackGroupId Value="-1" />
			<DeviceChain>
				<AutomationLanes>
					<AutomationLanes>
						<AutomationLane Id="0">
							<SelectedDevice Value="1" /><SelectedEnvelope Value="0" />
							<IsContentSelectedInDocument Value="false" /><LaneHeight Value="68" />
						</AutomationLane>
					</AutomationLanes>
					<AreAdditionalAutomationLanesFolded Value="false" />
				</AutomationLanes>
				<ClipEnvelopeChooserViewState>
					<SelectedDevice Value="1" /><SelectedEnvelope Value="0" /><PreferModulationVisible Value="false" />
				</ClipEnvelopeChooserViewState>
				<AudioInputRouting>
						<Target Value="AudioIn/External/S0" />
						<UpperDisplayString Value="Ext. In" />
						<LowerDisplayString Value="1/2" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</AudioInputRouting>
					<MidiInputRouting>
						<Target Value="MidiIn/External.All/-1" />
						<UpperDisplayString Value="Ext: All Ins" />
						<LowerDisplayString Value="" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</MidiInputRouting>
					<AudioOutputRouting>
						<Target Value="AudioOut/Master" />
						<UpperDisplayString Value="Master" />
						<LowerDisplayString Value="" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</AudioOutputRouting>
					<MidiOutputRouting>
						<Target Value="MidiOut/None" />
						<UpperDisplayString Value="None" />
						<LowerDisplayString Value="" />
						<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
					</MidiOutputRouting>
				<Mixer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{on_id}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="{pointee_id}" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<Sends />
					<Speaker>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{spk_id}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</Speaker>
					<SoloSink Value="false" /><PanMode Value="0" />
					<Pan>
						<LomId Value="0" /><Manual Value="0" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{pan_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{pan_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</Pan>
					<SplitStereoPanL>
						<LomId Value="0" /><Manual Value="-1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{spl_l_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{spl_l_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanL>
					<SplitStereoPanR>
						<LomId Value="0" /><Manual Value="1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{spl_r_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{spl_r_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanR>
					<Volume>
						<LomId Value="0" /><Manual Value="1" />
						<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1.99526231" /></MidiControllerRange>
						<AutomationTarget Id="{vol_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{vol_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</Volume>
					<ViewStateSesstionTrackWidth Value="93" />
					<CrossFadeState><LomId Value="0" /><Manual Value="1" /><AutomationTarget Id="{xfade_at}"><LockEnvelope Value="0" /></AutomationTarget></CrossFadeState>
					<Sends>
						<TrackSendHolder Id="0">
							<Send>
								<LomId Value="0" /><Manual Value="0.0003162277571" />
								<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1" /></MidiControllerRange>
								<AutomationTarget Id="{send0_at}"><LockEnvelope Value="0" /></AutomationTarget>
								<ModulationTarget Id="{send0_mt}"><LockEnvelope Value="0" /></ModulationTarget>
							</Send>
							<Active Value="false" />
						</TrackSendHolder>
						<TrackSendHolder Id="1">
							<Send>
								<LomId Value="0" /><Manual Value="0.0003162277571" />
								<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1" /></MidiControllerRange>
								<AutomationTarget Id="{send1_at}"><LockEnvelope Value="0" /></AutomationTarget>
								<ModulationTarget Id="{send1_mt}"><LockEnvelope Value="0" /></ModulationTarget>
							</Send>
							<Active Value="false" />
						</TrackSendHolder>
					</Sends>
					<SendsListWrapper LomId="0" />
				</Mixer>
				<DeviceChain>
					<Devices />
					<SignalModulations />
				</DeviceChain>
				<FreezeSequencer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{frz_on}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="{frz_pt}" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<ClipSlotList />
					<MonitoringEnum Value="1" />
					<Sample><ArrangerAutomation><Events /><AutomationTransformViewState><IsTransformPending Value="false" /><TimeAndValueTransforms /></AutomationTransformViewState></ArrangerAutomation></Sample>
					<VolumeModulationTarget Id="{frz_vol_mt}"><LockEnvelope Value="0" /></VolumeModulationTarget>
					<TranspositionModulationTarget Id="{frz_trans_mt}"><LockEnvelope Value="0" /></TranspositionModulationTarget>
					<GrainSizeModulationTarget Id="{frz_grain_mt}"><LockEnvelope Value="0" /></GrainSizeModulationTarget>
					<FluxModulationTarget Id="{frz_flux_mt}"><LockEnvelope Value="0" /></FluxModulationTarget>
					<SampleOffsetModulationTarget Id="{frz_soff_mt}"><LockEnvelope Value="0" /></SampleOffsetModulationTarget>
					<PitchViewScrollPosition Value="-1073741824" />
					<SampleOffsetModulationScrollPosition Value="-1073741824" />
					<Recorder><IsArmed Value="false" /><TakeCounter Value="1" /></Recorder>
				</FreezeSequencer>
			</DeviceChain>
		</ReturnTrack>'''

    # ── assemble all tracks ───────────────────────────────────────────────────
    n = len(clips)
    track_blocks = [audio_track(i, i, c) for i, c in enumerate(clips)]
    track_blocks.append(return_track(n,     "A-Return"))
    track_blocks.append(return_track(n + 1, "B-Return"))
    tracks_xml = '\n'.join(track_blocks)

    # ── locators XML ──────────────────────────────────────────────────────────
    # Always include COUNT OFF at beat 0
    all_locators = list(locators)
    if not any(loc['name'].upper() == 'COUNT OFF' for loc in all_locators):
        all_locators.insert(0, {'beat': 0.0, 'name': 'COUNT OFF'})
    loc_items = '\n'.join(
        f'''			<Locator Id="{i}">
				<LomId Value="0" />
				<Time Value="{repr(float(loc['beat']))}" />
				<Name Value="{loc['name']}" />
				<Annotation Value="" />
				<IsSongStart Value="false" />
			</Locator>'''
        for i, loc in enumerate(sorted(all_locators, key=lambda x: x['beat']))
    )

    # ── 8 minimal scenes ──────────────────────────────────────────────────────
    scenes_xml = '\n'.join(f'''		<Scene Id="{i}">
			<FollowAction>
				<FollowTime Value="4" /><IsLinked Value="true" /><LoopIterations Value="1" />
				<FollowActionA Value="4" /><FollowActionB Value="0" />
				<FollowChanceA Value="100" /><FollowChanceB Value="0" />
				<JumpIndexA Value="1" /><JumpIndexB Value="1" />
				<FollowActionEnabled Value="false" />
			</FollowAction>
			<Name Value="" /><Annotation Value="" /><Color Value="-1" />
			<Tempo Value="120" /><IsTempoEnabled Value="false" />
			<TimeSignatureId Value="{initial_ts_val}" /><IsTimeSignatureEnabled Value="false" />
			<LomId Value="0" /><ClipSlotsListWrapper LomId="0" />
		</Scene>''' for i in range(8))

    # ── master track minimal PreHear ──────────────────────────────────────────
    prehear_on = _nid(); prehear_spk = _nid(); prehear_pan_at = _nid(); prehear_pan_mt = _nid()
    prehear_vol_at = _nid(); prehear_vol_mt = _nid(); prehear_xfade_at = _nid(); prehear_pt = _nid()

    # ── final NextPointeeId ───────────────────────────────────────────────────
    next_id = _idc[0] + 100

    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Ableton MajorVersion="5" MinorVersion="11.0_11300" SchemaChangeCount="7" Creator="Ableton Live 11.3.43" Revision="">
	<LiveSet>
		<NextPointeeId Value="{next_id}" />
		<OverwriteProtectionNumber Value="2819" />
		<LomId Value="0" />
		<LomIdView Value="0" />
		<Tracks>
{tracks_xml}
		</Tracks>
		<MasterTrack>
			<LomId Value="0" /><LomIdView Value="0" />
			<IsContentSelectedInDocument Value="false" /><PreferredContentViewMode Value="0" />
			<TrackDelay><Value Value="0" /><IsValueSampleBased Value="false" /></TrackDelay>
			<Name>
				<EffectiveName Value="Master" /><UserName Value="" />
				<Annotation Value="" /><MemorizedFirstClipName Value="" />
			</Name>
			<Color Value="16" />
			<AutomationEnvelopes>
				<Envelopes>
					<AutomationEnvelope Id="0">
						<EnvelopeTarget><PointeeId Value="10" /></EnvelopeTarget>
						<Automation>
							<Events>
{ts_enum_events}
							</Events>
							<AutomationTransformViewState>
								<IsTransformPending Value="false" /><TimeAndValueTransforms />
							</AutomationTransformViewState>
						</Automation>
					</AutomationEnvelope>
					<AutomationEnvelope Id="1">
						<EnvelopeTarget><PointeeId Value="8" /></EnvelopeTarget>
						<Automation>
							<Events>
{tempo_float_events}
							</Events>
							<AutomationTransformViewState>
								<IsTransformPending Value="false" /><TimeAndValueTransforms />
							</AutomationTransformViewState>
						</Automation>
					</AutomationEnvelope>
				</Envelopes>
			</AutomationEnvelopes>
			<TrackGroupId Value="-1" /><TrackUnfolded Value="true" />
			<DevicesListWrapper LomId="0" /><ClipSlotsListWrapper LomId="0" />
			<ViewData Value="{{}}" />
			<TakeLanes><TakeLanes /><AreTakeLanesFolded Value="true" /></TakeLanes>
			<LinkedTrackGroupId Value="-1" />
			<DeviceChain>
				<AutomationLanes>
					<AutomationLanes>
						<AutomationLane Id="0">
							<SelectedDevice Value="1" /><SelectedEnvelope Value="0" />
							<IsContentSelectedInDocument Value="false" /><LaneHeight Value="85" />
						</AutomationLane>
					</AutomationLanes>
					<AreAdditionalAutomationLanesFolded Value="false" />
				</AutomationLanes>
				<ClipEnvelopeChooserViewState>
					<SelectedDevice Value="0" /><SelectedEnvelope Value="0" /><PreferModulationVisible Value="false" />
				</ClipEnvelopeChooserViewState>
				<AudioInputRouting>
					<Target Value="AudioIn/External/S0" /><UpperDisplayString Value="Ext. In" /><LowerDisplayString Value="1/2" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</AudioInputRouting>
				<MidiInputRouting>
					<Target Value="MidiIn/External.All/-1" /><UpperDisplayString Value="Ext: All Ins" /><LowerDisplayString Value="" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</MidiInputRouting>
				<AudioOutputRouting>
					<Target Value="AudioOut/External/S0" /><UpperDisplayString Value="Ext. Out" /><LowerDisplayString Value="1/2" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</AudioOutputRouting>
				<MidiOutputRouting>
					<Target Value="MidiOut/None" /><UpperDisplayString Value="None" /><LowerDisplayString Value="" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</MidiOutputRouting>
				<Mixer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="1"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="18" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<Sends />
					<Speaker>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="2"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</Speaker>
					<SoloSink Value="false" /><PanMode Value="0" />
					<Pan>
						<LomId Value="0" /><Manual Value="0" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="3"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="4"><LockEnvelope Value="0" /></ModulationTarget>
					</Pan>
					<SplitStereoPanL>
						<LomId Value="0" /><Manual Value="-1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="16175"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="16176"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanL>
					<SplitStereoPanR>
						<LomId Value="0" /><Manual Value="1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="16177"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="16178"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanR>
					<Volume>
						<LomId Value="0" /><Manual Value="1" />
						<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1.99526238" /></MidiControllerRange>
						<AutomationTarget Id="5"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="6"><LockEnvelope Value="0" /></ModulationTarget>
					</Volume>
					<ViewStateSesstionTrackWidth Value="93" />
					<CrossFadeState><LomId Value="0" /><Manual Value="1" /><AutomationTarget Id="7"><LockEnvelope Value="0" /></AutomationTarget></CrossFadeState>
					<SendsListWrapper LomId="0" />
					<Tempo>
						<LomId Value="0" />
						<Manual Value="{repr(float(bpm))}" />
						<MidiControllerRange><Min Value="60" /><Max Value="200" /></MidiControllerRange>
						<AutomationTarget Id="8"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="9"><LockEnvelope Value="0" /></ModulationTarget>
					</Tempo>
					<TimeSignature>
						<LomId Value="0" />
						<Manual Value="{initial_ts_val}" />
						<AutomationTarget Id="10"><LockEnvelope Value="0" /></AutomationTarget>
					</TimeSignature>
					<GlobalGrooveAmount>
						<LomId Value="0" /><Manual Value="100" />
						<MidiControllerRange><Min Value="0" /><Max Value="131.25" /></MidiControllerRange>
						<AutomationTarget Id="11"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="12"><LockEnvelope Value="0" /></ModulationTarget>
					</GlobalGrooveAmount>
					<CrossFade>
						<LomId Value="0" /><Manual Value="0" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="13"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="14"><LockEnvelope Value="0" /></ModulationTarget>
					</CrossFade>
					<TempoAutomationViewBottom Value="20" />
					<TempoAutomationViewTop Value="200" />
				</Mixer>
				<FreezeSequencer>
					<AudioSequencer Id="0">
						<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
						<On>
							<LomId Value="0" /><Manual Value="true" />
							<AutomationTarget Id="15"><LockEnvelope Value="0" /></AutomationTarget>
							<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
						</On>
						<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
						<Pointee Id="19" />
						<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
						<LastPresetRef><Value /></LastPresetRef>
						<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
						<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
						<ClipSlotList />
						<MonitoringEnum Value="1" />
						<Sample><ArrangerAutomation><Events /><AutomationTransformViewState><IsTransformPending Value="false" /><TimeAndValueTransforms /></AutomationTransformViewState></ArrangerAutomation></Sample>
						<VolumeModulationTarget Id="16"><LockEnvelope Value="0" /></VolumeModulationTarget>
						<TranspositionModulationTarget Id="17"><LockEnvelope Value="0" /></TranspositionModulationTarget>
						<GrainSizeModulationTarget Id="18"><LockEnvelope Value="0" /></GrainSizeModulationTarget>
						<FluxModulationTarget Id="20"><LockEnvelope Value="0" /></FluxModulationTarget>
						<SampleOffsetModulationTarget Id="16183"><LockEnvelope Value="0" /></SampleOffsetModulationTarget>
						<PitchViewScrollPosition Value="-1073741824" />
						<SampleOffsetModulationScrollPosition Value="-1073741824" />
						<Recorder><IsArmed Value="false" /><TakeCounter Value="1" /></Recorder>
					</AudioSequencer>
				</FreezeSequencer>
				<DeviceChain>
					<Devices />
					<SignalModulations />
				</DeviceChain>
			</DeviceChain>
		</MasterTrack>
		<PreHearTrack>
			<LomId Value="0" /><LomIdView Value="0" />
			<IsContentSelectedInDocument Value="false" /><PreferredContentViewMode Value="0" />
			<TrackDelay><Value Value="0" /><IsValueSampleBased Value="false" /></TrackDelay>
			<Name>
				<EffectiveName Value="Master" /><UserName Value="" />
				<Annotation Value="" /><MemorizedFirstClipName Value="" />
			</Name>
			<Color Value="-1" />
			<AutomationEnvelopes><Envelopes /></AutomationEnvelopes>
			<TrackGroupId Value="-1" /><TrackUnfolded Value="false" />
			<DevicesListWrapper LomId="0" /><ClipSlotsListWrapper LomId="0" />
			<ViewData Value="{{}}" />
			<TakeLanes><TakeLanes /><AreTakeLanesFolded Value="true" /></TakeLanes>
			<LinkedTrackGroupId Value="-1" />
			<DeviceChain>
				<AutomationLanes>
					<AutomationLanes>
						<AutomationLane Id="0">
							<SelectedDevice Value="0" /><SelectedEnvelope Value="0" />
							<IsContentSelectedInDocument Value="false" /><LaneHeight Value="85" />
						</AutomationLane>
					</AutomationLanes>
					<AreAdditionalAutomationLanesFolded Value="false" />
				</AutomationLanes>
				<ClipEnvelopeChooserViewState>
					<SelectedDevice Value="0" /><SelectedEnvelope Value="0" /><PreferModulationVisible Value="false" />
				</ClipEnvelopeChooserViewState>
				<AudioInputRouting>
					<Target Value="AudioIn/External/S0" /><UpperDisplayString Value="Ext. In" /><LowerDisplayString Value="1/2" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</AudioInputRouting>
				<MidiInputRouting>
					<Target Value="MidiIn/External.All/-1" /><UpperDisplayString Value="Ext: All Ins" /><LowerDisplayString Value="" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</MidiInputRouting>
				<AudioOutputRouting>
					<Target Value="AudioOut/External/S0" /><UpperDisplayString Value="Ext. Out" /><LowerDisplayString Value="1/2" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</AudioOutputRouting>
				<MidiOutputRouting>
					<Target Value="MidiOut/None" /><UpperDisplayString Value="None" /><LowerDisplayString Value="" />
					<MpeSettings><ZoneType Value="0" /><FirstNoteChannel Value="1" /><LastNoteChannel Value="15" /></MpeSettings>
				</MidiOutputRouting>
				<Mixer>
					<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />
					<On>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{prehear_on}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</On>
					<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />
					<Pointee Id="{prehear_pt}" />
					<LastSelectedTimeableIndex Value="0" /><LastSelectedClipEnvelopeIndex Value="0" />
					<LastPresetRef><Value /></LastPresetRef>
					<LockedScripts /><IsFolded Value="false" /><ShouldShowPresetName Value="false" />
					<UserName Value="" /><Annotation Value="" /><SourceContext><Value /></SourceContext>
					<Sends />
					<Speaker>
						<LomId Value="0" /><Manual Value="true" />
						<AutomationTarget Id="{prehear_spk}"><LockEnvelope Value="0" /></AutomationTarget>
						<MidiCCOnOffThresholds><Min Value="64" /><Max Value="127" /></MidiCCOnOffThresholds>
					</Speaker>
					<SoloSink Value="false" /><PanMode Value="0" />
					<Pan>
						<LomId Value="0" /><Manual Value="0" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="{prehear_pan_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{prehear_pan_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</Pan>
					<SplitStereoPanL>
						<LomId Value="0" /><Manual Value="-1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="16179"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="16180"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanL>
					<SplitStereoPanR>
						<LomId Value="0" /><Manual Value="1" />
						<MidiControllerRange><Min Value="-1" /><Max Value="1" /></MidiControllerRange>
						<AutomationTarget Id="16181"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="16182"><LockEnvelope Value="0" /></ModulationTarget>
					</SplitStereoPanR>
					<Volume>
						<LomId Value="0" /><Manual Value="0.7071067691" />
						<MidiControllerRange><Min Value="0.0003162277571" /><Max Value="1.99526238" /></MidiControllerRange>
						<AutomationTarget Id="{prehear_vol_at}"><LockEnvelope Value="0" /></AutomationTarget>
						<ModulationTarget Id="{prehear_vol_mt}"><LockEnvelope Value="0" /></ModulationTarget>
					</Volume>
					<ViewStateSesstionTrackWidth Value="74" />
					<CrossFadeState><LomId Value="0" /><Manual Value="1" /><AutomationTarget Id="{prehear_xfade_at}"><LockEnvelope Value="0" /></AutomationTarget></CrossFadeState>
					<SendsListWrapper LomId="0" />
				</Mixer>
			</DeviceChain>
		</PreHearTrack>
		<SendsPre>
			<SendPreBool Id="0" Value="false" />
			<SendPreBool Id="1" Value="false" />
		</SendsPre>
		<Scenes>
{scenes_xml}
		</Scenes>
		<Transport>
			<LoopOn Value="true" />
			<LoopStart Value="0" />
			<LoopLength Value="{repr(float(loop_end_beat))}" />
			<LoopIsSongStart Value="false" />
			<CurrentTime Value="0" />
			<PunchIn Value="false" />
			<PunchOut Value="false" />
			<MetronomeTickDuration Value="0" />
			<DrawMode Value="false" />
		</Transport>
		<SongMasterValues><SessionScrollerPos X="0" Y="0" /></SongMasterValues>
		<SignalModulations />
		<GlobalQuantisation Value="4" />
		<AutoQuantisation Value="0" />
		<Grid>
			<FixedNumerator Value="1" /><FixedDenominator Value="16" /><GridIntervalPixel Value="20" />
			<Ntoles Value="2" /><SnapToGrid Value="true" /><Fixed Value="false" />
		</Grid>
		<ScaleInformation><RootNote Value="0" /><Name Value="Major" /></ScaleInformation>
		<InKey Value="false" /><SmpteFormat Value="0" />
		<TimeSelection><AnchorTime Value="0" /><OtherTime Value="0" /></TimeSelection>
		<SequencerNavigator>
			<BeatTimeHelper><CurrentZoom Value="0.25" /></BeatTimeHelper>
			<ScrollerPos X="0" Y="0" /><ClientSize X="1200" Y="800" />
		</SequencerNavigator>
		<IsContentSelectedInDocument Value="false" />
		<SignalModulations />
		<ContentSplitterProperties>
			<IsExpanded Value="true" /><Height Value="300" /><Minimized Value="false" />
		</ContentSplitterProperties>
		<ViewStateSessionMixerHeight Value="120" />
		<Locators>
			<Locators>
{loc_items}
			</Locators>
		</Locators>
		<ViewStates>
			<SessionIO Value="1" /><SessionSends Value="1" /><SessionReturns Value="1" />
			<SessionMixer Value="1" /><SessionMixerI Value="1" />
			<ArrangerIO Value="1" /><ArrangerReturns Value="1" /><ArrangerMixer Value="1" />
		</ViewStates>
	</LiveSet>
</Ableton>'''

    import gzip as _gzip
    with _gzip.open(output_path, 'wb') as f:
        f.write(xml.encode('utf-8'))
    return {"path": output_path}


def run_server():
    """Long-running mode: read file paths from stdin, write JSON to stdout.
    Protocol:
      - Swift sends a file path (one line)
      - Python responds with a single line of JSON
      - Repeat until stdin closes
    Pre-imports dawtool so parsing is instant.
    """
    # Pre-import everything so first parse/detect is fast
    import dawtool  # noqa
    from dawtool import load_project  # noqa
    import librosa  # noqa — pre-warm for detect_key
    import numpy  # noqa

    # Signal ready
    print(json.dumps({"ready": True}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        # JSON command (e.g. fix_locators) — starts with '{'
        if line.startswith("{"):
            try:
                cmd    = json.loads(line)
                action = cmd.get("action", "")
                if action == "fix_locators":
                    result = _fix_locators(cmd["path"], cmd.get("fixes", []))
                    print(json.dumps(result), flush=True)
                elif action == "downgrade_to_live11":
                    result = _downgrade_to_live11(cmd["path"])
                    print(json.dumps(result), flush=True)
                elif action == "detect_key":
                    result = _detect_key(cmd["path"])
                    print(json.dumps(result), flush=True)
                elif action == "save_als_edits":
                    result = _save_als_edits(
                        cmd["path"],
                        cmd.get("tempo_events", []),
                        cmd.get("time_sig_events", []),
                        cmd.get("locator_overrides", []),
                        new_locators=cmd.get("new_locators") or None,
                        output_path=cmd.get("output_path") or None,
                    )
                    print(json.dumps(result), flush=True)
                elif action == "generate_click_track":
                    result = _generate_click_track(
                        output_path      = cmd["output_path"],
                        bpm              = float(cmd.get("bpm", 120.0)),
                        time_sig         = cmd.get("time_sig", "4/4"),
                        duration_seconds = float(cmd.get("duration_seconds", 0.0)),
                        tempo_events     = cmd.get("tempo_events") or [],
                        time_sig_events  = cmd.get("time_sig_events") or [],
                    )
                    print(json.dumps(result), flush=True)
                elif action == "generate_als":
                    result = _generate_als(
                        output_path=cmd["output_path"],
                        clips=cmd.get("clips", []),
                        bpm=float(cmd.get("bpm", 120.0)),
                        tempo_events=cmd.get("tempo_events", []),
                        time_signatures=cmd.get("time_signatures", []),
                        locators=cmd.get("locators", []),
                        loop_end_beat=float(cmd.get("loop_end_beat", 0.0)),
                    )
                    print(json.dumps(result), flush=True)
                else:
                    print(json.dumps({"error": f"Unknown action: {action}"}), flush=True)
            except Exception as e:
                print(json.dumps({"error": str(e)}), flush=True)
        else:
            # Legacy path-only parse
            print(parse_file(line), flush=True)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--server":
        run_server()
        return

    if len(sys.argv) < 2:
        print(json.dumps({"error": "No file path provided", "markers": [], "time_signatures": [], "file": "", "bpm": None, "warnings": []}))
        sys.exit(1)

    path = sys.argv[1]
    print(parse_file(path))


if __name__ == "__main__":
    main()
