import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/main.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:window_size/window_size.dart' as window_size;

// Team edition: the default size (logical px) of a session window and its
// satellite toolbar window.
const double kTeamSessionDefaultW = 500;
const double kTeamSessionDefaultH = 500;

// Team edition: the visible frame of the monitor that currently holds the main
// (home) window, so session + toolbar windows open on the same monitor. Runs
// in the MAIN window thread, so getWindowInfo() reports the main window. Using
// window_size for BOTH the window's screen and the screen frame keeps the
// coordinate systems consistent (mixing window_manager.getBounds with
// window_size screens picks the wrong monitor on multi-display setups).
Future<Rect?> teamHomeMonitorFrame() async {
  try {
    final info = await window_size.getWindowInfo();
    final screen = info.screen;
    if (screen != null) return screen.visibleFrame;
    final screens = await window_size.getScreenList();
    if (screens.isNotEmpty) return screens.first.visibleFrame;
  } catch (e) {
    debugPrint('teamHomeMonitorFrame: $e');
  }
  return null;
}

/// must keep the order
// ignore: constant_identifier_names
enum WindowType {
  Main,
  RemoteDesktop,
  FileTransfer,
  ViewCamera,
  PortForward,
  Terminal,
  Unknown,
  // Team edition: separate always-opaque toolbar window for a session.
  // Placed AFTER Unknown so existing indices (used in IPC) do not shift.
  RemoteToolbar,
}

extension Index on int {
  WindowType get windowType {
    switch (this) {
      case 0:
        return WindowType.Main;
      case 1:
        return WindowType.RemoteDesktop;
      case 2:
        return WindowType.FileTransfer;
      case 3:
        return WindowType.ViewCamera;
      case 4:
        return WindowType.PortForward;
      case 5:
        return WindowType.Terminal;
      case 7:
        return WindowType.RemoteToolbar;
      default:
        return WindowType.Unknown;
    }
  }
}

class MultiWindowCallResult {
  int windowId;
  dynamic result;

  MultiWindowCallResult(this.windowId, this.result);
}

/// Window Manager
/// mainly use it in `Main Window`
/// use it in sub window is not recommended
class RustDeskMultiWindowManager {
  RustDeskMultiWindowManager._();

  static final instance = RustDeskMultiWindowManager._();

  final Set<int> _inactiveWindows = {};
  final Set<int> _activeWindows = {};
  final List<AsyncCallback> _windowActiveCallbacks = List.empty(growable: true);
  final List<int> _remoteDesktopWindows = List.empty(growable: true);
  final List<int> _fileTransferWindows = List.empty(growable: true);
  final List<int> _viewCameraWindows = List.empty(growable: true);
  final List<int> _portForwardWindows = List.empty(growable: true);
  final List<int> _terminalWindows = List.empty(growable: true);
  // Team edition: session window id -> its satellite toolbar window id.
  // Kept OUT of the active-window lifecycle so it never affects app close.
  final Map<int, int> _toolbarForSessionWindow = {};

  moveTabToNewWindow(int windowId, String peerId, String sessionId,
      WindowType windowType) async {
    var params = {
      'type': windowType.index,
      'id': peerId,
      'tab_window_id': windowId,
      'session_id': sessionId,
    };
    if (windowType == WindowType.RemoteDesktop) {
      await _newSession(
        false,
        WindowType.RemoteDesktop,
        kWindowEventNewRemoteDesktop,
        peerId,
        _remoteDesktopWindows,
        jsonEncode(params),
      );
    } else if (windowType == WindowType.ViewCamera) {
      await _newSession(
        false,
        WindowType.ViewCamera,
        kWindowEventNewViewCamera,
        peerId,
        _viewCameraWindows,
        jsonEncode(params),
      );
    }
  }

  // This function must be called in the main window thread.
  // Because the _remoteDesktopWindows is managed in that thread.
  openMonitorSession(int windowId, String peerId, int display, int displayCount,
      Rect? screenRect, int windowType) async {
    final isCamera = windowType == WindowType.ViewCamera.index;
    final windowIDs = isCamera ? _viewCameraWindows : _remoteDesktopWindows;
    if (windowIDs.length > 1) {
      for (final windowId in windowIDs) {
        if (await DesktopMultiWindow.invokeMethod(
            windowId,
            kWindowEventActiveDisplaySession,
            jsonEncode({
              'id': peerId,
              'display': display,
            }))) {
          return;
        }
      }
    }

    final displays = display == kAllDisplayValue
        ? List.generate(displayCount, (index) => index)
        : [display];
    var params = {
      'type': windowType,
      'id': peerId,
      'tab_window_id': windowId,
      'display': display,
      'displays': displays,
    };
    if (screenRect != null) {
      params['screen_rect'] = {
        'l': screenRect.left,
        't': screenRect.top,
        'r': screenRect.right,
        'b': screenRect.bottom,
      };
    }
    await _newSession(
      false,
      windowType.windowType,
      isCamera ? kWindowEventNewViewCamera : kWindowEventNewRemoteDesktop,
      peerId,
      windowIDs,
      jsonEncode(params),
      screenRect: screenRect,
    );
  }

  Future<int> newSessionWindow(
    WindowType type,
    String remoteId,
    String msg,
    List<int> windows,
    bool withScreenRect,
  ) async {
    var windowMsg = msg;
    if (kTeamLanOnly && type == WindowType.RemoteDesktop) {
      // Team edition: pass the home monitor into the new window so it can open
      // at a default size on the same monitor as home, and never restore the
      // closed fullscreen/position state. The session window applies this in
      // its own startup (main.dart), which is the only place that reliably runs
      // AFTER the window (which may restore fullscreen) is up.
      try {
        final hm = await teamHomeMonitorFrame();
        if (hm != null) {
          final m = jsonDecode(msg) as Map<String, dynamic>;
          m['team_home_monitor'] = {
            'l': hm.left,
            't': hm.top,
            'r': hm.right,
            'b': hm.bottom,
          };
          windowMsg = jsonEncode(m);
        }
      } catch (e) {
        debugPrint('inject team_home_monitor: $e');
      }
    }
    final windowController = await DesktopMultiWindow.createWindow(windowMsg);
    if (isWindows) {
      windowController.setInitBackgroundColor(Colors.black);
    }
    final windowId = windowController.windowId;
    if (kTeamLanOnly && type == WindowType.RemoteDesktop && !withScreenRect) {
      // Frame/fullscreen is handled by the session window's own startup; just
      // set the title here.
      windowController
          .setTitle(getWindowNameWithId(remoteId, overrideType: type));
    } else if (!withScreenRect) {
      windowController
        ..setFrame(const Offset(0, 0) &
            Size(1280 + windowId * 20, 720 + windowId * 20))
        ..center()
        ..setTitle(getWindowNameWithId(
          remoteId,
          overrideType: type,
        ));
    } else {
      windowController.setTitle(getWindowNameWithId(
        remoteId,
        overrideType: type,
      ));
    }
    if (isMacOS || isWindows) {
      Future.microtask(() => windowController.show());
    }
    registerActiveWindow(windowId);
    windows.add(windowId);
    if (kTeamLanOnly && type == WindowType.RemoteDesktop) {
      // Team edition: open the separate always-opaque toolbar window as a
      // satellite of this session window. Fire-and-forget; errors are swallowed
      // so it can never affect the session window just created.
      openTeamToolbarWindow(remoteId, windowId).catchError((e) {
        debugPrint('openTeamToolbarWindow failed: $e');
        return null;
      });
    }
    return windowId;
  }

  // Team edition: open a separate always-opaque toolbar window bound to a
  // session window. Must be called in the main window thread.
  //
  // IMPORTANT: this is a *satellite* window. It is deliberately NOT registered
  // via registerActiveWindow and NOT added to any window-type list, so it never
  // participates in the active-window lifecycle (`onActiveWindowChanged` closes
  // the app when the active set empties). It stays fully opaque while the
  // session window fades (LWA_ALPHA).
  Future<int?> openTeamToolbarWindow(String peerId, int sessionWindowId) async {
    if (!kTeamLanOnly) return null;
    final existing = _toolbarForSessionWindow[sessionWindowId];
    if (existing != null) return existing;
    final msg = jsonEncode({
      'type': WindowType.RemoteToolbar.index,
      'id': peerId,
      'session_window_id': sessionWindowId,
    });
    final controller = await DesktopMultiWindow.createWindow(msg);
    if (isWindows) {
      controller.setInitBackgroundColor(Colors.black);
    }
    final wid = controller.windowId;
    const double tw = 760, th = 60, margin = 24;
    final hm = await teamHomeMonitorFrame();
    final frame = hm != null
        ? Rect.fromLTWH(
            hm.right - tw - margin, hm.bottom - th - margin, tw, th)
        : const Rect.fromLTWH(200, 200, tw, th);
    controller
      ..setFrame(frame)
      ..setTitle('Toolbar');
    Future.microtask(() => controller.show());
    _toolbarForSessionWindow[sessionWindowId] = wid;
    return wid;
  }

  Future<MultiWindowCallResult> _newSession(
    bool openInTabs,
    WindowType type,
    String methodName,
    String remoteId,
    List<int> windows,
    String msg, {
    Rect? screenRect,
  }) async {
    if (openInTabs) {
      if (windows.isEmpty) {
        final windowId = await newSessionWindow(
            type, remoteId, msg, windows, screenRect != null);
        if (isWindows) {
          await windowOnTop(windowId);
        }
        return MultiWindowCallResult(windowId, null);
      } else {
        return call(type, methodName, msg);
      }
    } else {
      if (_inactiveWindows.isNotEmpty) {
        for (final windowId in windows) {
          if (_inactiveWindows.contains(windowId)) {
            if (screenRect == null) {
              await restoreWindowPosition(type,
                  windowId: windowId, peerId: remoteId);
            }
            await DesktopMultiWindow.invokeMethod(windowId, methodName, msg);
            if (methodName != kWindowEventNewRemoteDesktop) {
              WindowController.fromWindowId(windowId).show();
            }
            registerActiveWindow(windowId);
            return MultiWindowCallResult(windowId, null);
          }
        }
      }
      final windowId = await newSessionWindow(
          type, remoteId, msg, windows, screenRect != null);
      if (isWindows) {
        await windowOnTop(windowId);
      }
      return MultiWindowCallResult(windowId, null);
    }
  }

  Future<MultiWindowCallResult> newSession(
    WindowType type,
    String methodName,
    String remoteId,
    List<int> windows, {
    String? password,
    String loginMethod = '',
    bool? forceRelay,
    String? switchUuid,
    bool? isRDP,
    bool? isSharedPassword,
    String? connToken,
  }) async {
    var params = {
      "type": type.index,
      "id": remoteId,
      "password": password,
      "forceRelay": forceRelay
    };
    if (switchUuid != null) {
      params['switch_uuid'] = switchUuid;
    }
    if (isRDP != null) {
      params['isRDP'] = isRDP;
    }
    if (isSharedPassword != null) {
      params['isSharedPassword'] = isSharedPassword;
    }
    if (connToken != null) {
      params['connToken'] = connToken;
    }
    if (loginMethod.isNotEmpty) {
      params['loginMethod'] = loginMethod;
    }
    final msg = jsonEncode(params);

    // separate window for file transfer is not supported
    bool openInTabs = type != WindowType.RemoteDesktop ||
        mainGetLocalBoolOptionSync(kOptionOpenNewConnInTabs);

    if (windows.length > 1 || !openInTabs) {
      for (final windowId in windows) {
        if (await DesktopMultiWindow.invokeMethod(
            windowId, kWindowEventActiveSession, remoteId)) {
          return MultiWindowCallResult(windowId, null);
        }
      }
    }

    return _newSession(openInTabs, type, methodName, remoteId, windows, msg);
  }

  Future<MultiWindowCallResult> newRemoteDesktop(
    String remoteId, {
    String? password,
    String loginMethod = '',
    bool? isSharedPassword,
    String? switchUuid,
    bool? forceRelay,
  }) async {
    return await newSession(
      WindowType.RemoteDesktop,
      kWindowEventNewRemoteDesktop,
      remoteId,
      _remoteDesktopWindows,
      password: password,
      loginMethod: loginMethod,
      forceRelay: forceRelay,
      switchUuid: switchUuid,
      isSharedPassword: isSharedPassword,
    );
  }

  Future<MultiWindowCallResult> newFileTransfer(
    String remoteId, {
    String? password,
    String loginMethod = '',
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) async {
    return await newSession(
      WindowType.FileTransfer,
      kWindowEventNewFileTransfer,
      remoteId,
      _fileTransferWindows,
      password: password,
      loginMethod: loginMethod,
      forceRelay: forceRelay,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
    );
  }

  Future<MultiWindowCallResult> newViewCamera(
    String remoteId, {
    String? password,
    String loginMethod = '',
    bool? isSharedPassword,
    String? switchUuid,
    bool? forceRelay,
    String? connToken,
  }) async {
    return await newSession(
      WindowType.ViewCamera,
      kWindowEventNewViewCamera,
      remoteId,
      _viewCameraWindows,
      password: password,
      loginMethod: loginMethod,
      forceRelay: forceRelay,
      switchUuid: switchUuid,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
    );
  }

  Future<MultiWindowCallResult> newPortForward(
    String remoteId,
    bool isRDP, {
    String? password,
    String loginMethod = '',
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) async {
    return await newSession(
      WindowType.PortForward,
      kWindowEventNewPortForward,
      remoteId,
      _portForwardWindows,
      password: password,
      loginMethod: loginMethod,
      forceRelay: forceRelay,
      isRDP: isRDP,
      isSharedPassword: isSharedPassword,
      connToken: connToken,
    );
  }

  Future<MultiWindowCallResult> newTerminal(
    String remoteId, {
    String? password,
    String loginMethod = '',
    bool? isSharedPassword,
    bool? forceRelay,
    String? connToken,
  }) async {
    // Iterate through terminal windows in reverse order to prioritize
    // the most recently added or used windows, as they are more likely
    // to have an active session.
    for (final windowId in _terminalWindows.reversed) {
      if (await DesktopMultiWindow.invokeMethod(
          windowId, kWindowEventActiveSession, remoteId)) {
        return MultiWindowCallResult(windowId, null);
      }
    }

    // Terminal windows should always create new windows, not reuse
    // This avoids the MissingPluginException when trying to invoke
    // new_terminal on an inactive window
    var params = {
      "type": WindowType.Terminal.index,
      "id": remoteId,
      "password": password,
      "forceRelay": forceRelay,
      "isSharedPassword": isSharedPassword,
      "connToken": connToken,
    };
    if (loginMethod.isNotEmpty) {
      params['loginMethod'] = loginMethod;
    }
    final msg = jsonEncode(params);

    // Always create a new window for terminal
    final windowId = await newSessionWindow(
        WindowType.Terminal, remoteId, msg, _terminalWindows, false);
    return MultiWindowCallResult(windowId, null);
  }

  Future<MultiWindowCallResult> call(
      WindowType type, String methodName, dynamic args) async {
    final wnds = _findWindowsByType(type);
    if (wnds.isEmpty) {
      return MultiWindowCallResult(kInvalidWindowId, null);
    }
    for (final windowId in wnds) {
      if (_activeWindows.contains(windowId)) {
        final res =
            await DesktopMultiWindow.invokeMethod(windowId, methodName, args);
        return MultiWindowCallResult(windowId, res);
      }
    }
    final res =
        await DesktopMultiWindow.invokeMethod(wnds[0], methodName, args);
    return MultiWindowCallResult(wnds[0], res);
  }

  List<int> _findWindowsByType(WindowType type) {
    switch (type) {
      case WindowType.Main:
        return [kMainWindowId];
      case WindowType.RemoteDesktop:
        return _remoteDesktopWindows;
      case WindowType.FileTransfer:
        return _fileTransferWindows;
      case WindowType.ViewCamera:
        return _viewCameraWindows;
      case WindowType.PortForward:
        return _portForwardWindows;
      case WindowType.Terminal:
        return _terminalWindows;
      case WindowType.RemoteToolbar:
        // Satellite window: not tracked in the active-window lifecycle.
        break;
      case WindowType.Unknown:
        break;
    }
    return [];
  }

  void clearWindowType(WindowType type) {
    switch (type) {
      case WindowType.Main:
        return;
      case WindowType.RemoteDesktop:
        _remoteDesktopWindows.clear();
        break;
      case WindowType.FileTransfer:
        _fileTransferWindows.clear();
        break;
      case WindowType.ViewCamera:
        _viewCameraWindows.clear();
        break;
      case WindowType.PortForward:
        _portForwardWindows.clear();
        break;
      case WindowType.Terminal:
        _terminalWindows.clear();
        break;
      case WindowType.RemoteToolbar:
        break;
      case WindowType.Unknown:
        break;
    }
  }

  void setMethodHandler(
      Future<dynamic> Function(MethodCall call, int fromWindowId)? handler) {
    DesktopMultiWindow.setMethodHandler(handler);
  }

  Future<void> closeAllSubWindows() async {
    await Future.wait(WindowType.values.map((e) => _closeWindows(e)));
  }

  Future<void> _closeWindows(WindowType type) async {
    if (type == WindowType.Main) {
      // skip main window, use window manager instead
      return;
    }

    List<int> windows = [];
    try {
      windows = _findWindowsByType(type);
    } catch (e) {
      debugPrint('Failed to getAllSubWindowIds of $type, $e');
      return;
    }

    if (windows.isEmpty) {
      return;
    }
    for (int i = 0; i < windows.length; i++) {
      final wId = windows[i];
      final shouldSavePos = type != WindowType.Terminal || i == windows.length - 1;
      if (shouldSavePos) {
        debugPrint("closing multi window, type: ${type.toString()} id: $wId");
        try {
          await saveWindowPosition(type, windowId: wId);
        } catch (e) {
          debugPrint('Failed to save window position of $wId, $e');
        }
      }
      try {
        await WindowController.fromWindowId(wId).setPreventClose(false);
        await WindowController.fromWindowId(wId).close();
        _activeWindows.remove(wId);
      } catch (e) {
        debugPrint("$e");
        return;
      }
    }
    clearWindowType(type);
  }

  Future<List<int>> getAllSubWindowIds() async {
    try {
      final windows = await DesktopMultiWindow.getAllSubWindowIds();
      return windows;
    } catch (err) {
      if (err is AssertionError) {
        return [];
      } else {
        rethrow;
      }
    }
  }

  Set<int> getActiveWindows() {
    return _activeWindows;
  }

  Future<void> _notifyActiveWindow() async {
    for (final callback in _windowActiveCallbacks) {
      await callback.call();
    }
  }

  Future<void> registerActiveWindow(int windowId) async {
    _activeWindows.add(windowId);
    _inactiveWindows.remove(windowId);
    await _notifyActiveWindow();
  }

  /// Remove active window which has [`windowId`]
  ///
  /// [Availability]
  /// This function should only be called from main window.
  /// For other windows, please post a unregister(hide) event to main window handler:
  /// `rustDeskWinManager.call(WindowType.Main, kWindowEventHide, {"id": windowId!});`
  Future<void> unregisterActiveWindow(int windowId) async {
    _activeWindows.remove(windowId);
    if (windowId != kMainWindowId) {
      _inactiveWindows.add(windowId);
    }
    await _notifyActiveWindow();
  }

  void registerActiveWindowListener(AsyncCallback callback) {
    _windowActiveCallbacks.add(callback);
  }

  void unregisterActiveWindowListener(AsyncCallback callback) {
    _windowActiveCallbacks.remove(callback);
  }

  // This function is called from the main window.
  // It will query the active remote windows to get their coords.
  Future<List<String>> getOtherRemoteWindowCoords(int wId) async {
    List<String> coords = [];
    for (final windowId in _remoteDesktopWindows) {
      if (windowId != wId) {
        if (_activeWindows.contains(windowId)) {
          final res = await DesktopMultiWindow.invokeMethod(
              windowId, kWindowEventRemoteWindowCoords, '');
          if (res != null) {
            coords.add(res);
          }
        }
      }
    }
    return coords;
  }

  // This function is called from one remote window.
  // Only the main window knows `_remoteDesktopWindows` and `_activeWindows`.
  // So we need to call the main window to get the other remote windows' coords.
  Future<List<RemoteWindowCoords>> getOtherRemoteWindowCoordsFromMain() async {
    List<RemoteWindowCoords> coords = [];
    // Call the main window to get the coords of other remote windows.
    String res = await DesktopMultiWindow.invokeMethod(
        kMainWindowId, kWindowEventRemoteWindowCoords, kWindowId.toString());
    List<dynamic> list = jsonDecode(res);
    for (var item in list) {
      coords.add(RemoteWindowCoords.fromJson(jsonDecode(item)));
    }
    return coords;
  }
}

final rustDeskWinManager = RustDeskMultiWindowManager.instance;
