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
                            results.append((real_time, num, denom))
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
            deduped.append(entry)

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
            deduped.append((0.0, ts_num, ts_den))
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
        return [(r[0], r[2]) for r in result]  # list of (id, name_raw)
    except Exception:
        return []


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
    content = re.sub(r'(<Ableton\b[^>]*?)SchemaChangeCount="[^"]*"',
                     r'\1SchemaChangeCount="7"', content)

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
    content = re.sub(r'\s*<IsInKey\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<ScaleInformation>.*?</ScaleInformation>', '',
                     content, flags=re.DOTALL)
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

    # 13. Remove Live-12 MIDI editor expression/content lane elements
    content = re.sub(r'\s*<ExpressionLanes>.*?</ExpressionLanes>', '',
                     content, flags=re.DOTALL)
    content = re.sub(r'\s*<ContentLanes>.*?</ContentLanes>', '',
                     content, flags=re.DOTALL)
    content = re.sub(r'\s*<IsContentSplitterOpen\s+Value="[^"]*"\s*/>', '', content)
    content = re.sub(r'\s*<IsExpressionSplitterOpen\s+Value="[^"]*"\s*/>', '', content)

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

    # 3. Loop bracket and clip must match
    diff = abs(ref_clip["end"] - loop_end)
    if diff > 0.001:
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

        locator_data = _extract_locator_data(path)  # list of (id, name_raw)
        markers = [
            {"time": fmt_time(m.time),
             "time_end": "",  # filled in below
             # Use the raw name from XML so leading/trailing spaces are preserved
             # (dawtool strips them, which would hide extra-space locator errors).
             "text": locator_data[i][1] if i < len(locator_data) else m.text,
             "als_id": locator_data[i][0] if i < len(locator_data) else ""}
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
        # Filter out the phantom sentinel event (beat < 0).
        try:
            raw_tempo_events = _get_tempo_events(proj.contents)
            tempo_events = [[beat, bpm_val] for beat, bpm_val in raw_tempo_events if beat >= 0]
        except Exception:
            tempo_events = []

        return json.dumps({
            "error": None,
            "file": os.path.basename(path),
            "live_major_version": live_major_version,
            "bpm": bpm,
            "markers": markers,
            "time_signatures": [
                {"time": fmt_time(t), "sig": f"{n}/{d}"}
                for t, n, d in time_sigs
            ],
            "warnings": validation["warnings"],
            "session_info": validation["session_info"],
            "expected_duration": expected_duration,
            "first_tempo_change_marker_index": first_tempo_change_marker_index,
            "tempo_events": tempo_events,
        })

    except FileNotFoundError:
        return json.dumps({"error": f"File not found: {path}", "markers": [], "time_signatures": [], "file": "", "bpm": None, "warnings": []})
    except Exception as e:
        return json.dumps({"error": str(e), "markers": [], "time_signatures": [], "file": "", "bpm": None, "warnings": []})


def run_server():
    """Long-running mode: read file paths from stdin, write JSON to stdout.
    Protocol:
      - Swift sends a file path (one line)
      - Python responds with a single line of JSON
      - Repeat until stdin closes
    Pre-imports dawtool so parsing is instant.
    """
    # Pre-import everything so first parse is fast
    import dawtool  # noqa
    from dawtool import load_project  # noqa

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
