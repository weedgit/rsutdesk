import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Team edition: a separate always-opaque top-level window that hosts controls
/// for a session.
///
/// The session window uses a uniform native alpha (LWA_ALPHA) that fades the
/// whole window - including any in-window toolbar. This satellite window is
/// never faded, so its controls stay fully opaque (100%) while the session
/// image fades.
///
/// M2: a working opacity control. The slider does NOT fade this window; it
/// sends the value to the *session* window over the existing `team_opacity`
/// method channel, which applies the LWA_ALPHA fade there. No session FFI is
/// needed for this. (Full toolbar menus, which need a live second FFI, are a
/// later milestone.)
class TeamToolbarWindowScreen extends StatelessWidget {
  final Map<String, dynamic> params;

  const TeamToolbarWindowScreen({Key? key, required this.params})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final String peerId = (params['id'] ?? '').toString();
    final int? sessionWindowId =
        (params['session_window_id'] as num?)?.toInt();
    final int? selfWindowId = (params['windowId'] as num?)?.toInt();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF202124),
        body: _TeamToolbarBar(
          peerId: peerId,
          sessionWindowId: sessionWindowId,
          selfWindowId: selfWindowId,
        ),
      ),
    );
  }
}

class _TeamToolbarBar extends StatefulWidget {
  final String peerId;
  final int? sessionWindowId;
  final int? selfWindowId;

  const _TeamToolbarBar({
    Key? key,
    required this.peerId,
    required this.sessionWindowId,
    required this.selfWindowId,
  }) : super(key: key);

  @override
  State<_TeamToolbarBar> createState() => _TeamToolbarBarState();
}

class _TeamToolbarBarState extends State<_TeamToolbarBar> {
  late double _value;

  @override
  void initState() {
    super.initState();
    _value = getTeamRemoteWindowOpacity().toDouble();
    // Keep this toolbar window above everything, including a fullscreen session
    // window, so it stays reachable.
    const MethodChannel('org.rustdesk.rustdesk/team_window')
        .invokeMethod('setAlwaysOnTop', true)
        .catchError((e) {
      debugPrint('team toolbar setAlwaysOnTop: $e');
      return null;
    });
  }

  // Apply [v]% opacity to the SESSION window (not this one), and persist it.
  void _apply(double v, {bool save = false}) {
    setState(() => _value = v);
    final percent = v.round();
    final sid = widget.sessionWindowId;
    if (sid != null) {
      DesktopMultiWindow.invokeMethod(sid, kWindowEventTeamOpacity, percent)
          .catchError((e) {
        debugPrint('team toolbar -> session setOpacity: $e');
        return null;
      });
    }
    if (save) {
      bind.mainSetLocalOption(
          key: kOptionTeamRemoteWindowOpacity, value: percent.toString());
    }
  }

  // Forward a command to the SESSION window, which runs it on the real FFI.
  void _sendCmd(String cmd) {
    final sid = widget.sessionWindowId;
    if (sid == null) return;
    DesktopMultiWindow.invokeMethod(sid, kWindowEventTeamToolbarCmd,
        jsonEncode({'cmd': cmd, 'id': widget.peerId})).catchError((e) {
      debugPrint('team toolbar -> session cmd $cmd: $e');
      return null;
    });
  }

  Widget _cmdButton(IconData icon, String tooltip, String cmd, {Color? color}) {
    return IconButton(
      icon: Icon(icon, size: 18, color: color ?? Colors.white70),
      tooltip: tooltip,
      splashRadius: 18,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
      onPressed: () => _sendCmd(cmd),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          // Drag handle: click and drag here to move this toolbar window.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              final id = widget.selfWindowId;
              if (id != null) {
                WindowController.fromWindowId(id).startDragging();
              }
            },
            child: const MouseRegion(
              cursor: SystemMouseCursors.move,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.drag_indicator, size: 18, color: Colors.white38),
              ),
            ),
          ),
          _cmdButton(Icons.lock_outline, 'Lock remote', 'lock'),
          _cmdButton(Icons.keyboard, 'Ctrl+Alt+Del', 'cad'),
          _cmdButton(Icons.refresh, 'Refresh', 'refresh'),
          _cmdButton(Icons.crop_square, 'Default window size', 'defaultsize'),
          _cmdButton(Icons.link_off, 'Disconnect', 'disconnect',
              color: Colors.redAccent),
          const SizedBox(width: 6),
          const VerticalDivider(width: 1, color: Colors.white24, indent: 8, endIndent: 8),
          const SizedBox(width: 6),
          const Icon(Icons.opacity, size: 16, color: Colors.white70),
          Expanded(
            child: Slider(
              value: _value.clamp(kTeamRemoteWindowOpacityMin.toDouble(),
                  kTeamRemoteWindowOpacityMax.toDouble()),
              min: kTeamRemoteWindowOpacityMin.toDouble(),
              max: kTeamRemoteWindowOpacityMax.toDouble(),
              divisions:
                  (kTeamRemoteWindowOpacityMax - kTeamRemoteWindowOpacityMin),
              activeColor: cs.primary,
              label: '${_value.round()}%',
              onChanged: (v) => _apply(v),
              onChangeEnd: (v) => _apply(v, save: true),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text('${_value.round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
